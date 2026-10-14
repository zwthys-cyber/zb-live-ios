import Foundation

enum PlaylistParser {
    static let maximumBytes = 5 * 1024 * 1024
    static let maximumChannels = 5000

    static func parse(_ data: Data, baseURL: URL? = nil) throws -> [LiveItem] {
        guard data.count <= maximumBytes else { throw LiveError.tooLarge }
        guard let raw = String(data: data, encoding: .utf8) else { throw LiveError.noItems }
        let text = raw.replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LiveError.noItems }
        if text.hasPrefix("[") || text.hasPrefix("{") { return try parseJSON(data, baseURL: baseURL) }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-TARGETDURATION:") || $0.hasPrefix("#EXT-X-STREAM-INF:") || $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") }) {
            throw LiveError.hlsPlaylist
        }
        var output: [LiveItem] = []
        var name = ""
        var group = ""
        var explicitM3U = false
        for line in lines {
            if line.hasPrefix("#EXTM3U") { explicitM3U = true; continue }
            if line.hasPrefix("#EXTINF:") {
                name = titleAfterComma(line)
                group = attribute("group-title", in: line)
                explicitM3U = true
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let url = resolvedURL(line, baseURL: baseURL) {
                output.append(LiveItem(name: name, url: url, kind: explicitM3U ? .media : nil, group: group))
            }
            name = ""
            group = ""
            if output.count >= maximumChannels { break }
        }
        return try deduplicate(output)
    }

    private static func titleAfterComma(_ line: String) -> String {
        var quoted = false
        for index in line.indices {
            if line[index] == "\"" { quoted.toggle() }
            if line[index] == ",", !quoted {
                return String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    private static func attribute(_ key: String, in line: String) -> String {
        guard let start = line.range(of: key + "=\"")?.upperBound,
              let end = line[start...].firstIndex(of: "\"") else { return "" }
        return String(line[start..<end])
    }

    private static func resolvedURL(_ text: String, baseURL: URL?) -> URL? {
        guard text.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return nil }
        if let url = try? LinkValidator.parse(text) { return url }
        guard let baseURL, !text.contains("://"), !text.hasPrefix("javascript:"),
              let url = URL(string: text, relativeTo: baseURL)?.absoluteURL else { return nil }
        return try? LinkValidator.parse(url.absoluteString)
    }

    private static func parseJSON(_ data: Data, baseURL: URL?) throws -> [LiveItem] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw LiveError.invalidJSON }
        func rows(_ value: Any, depth: Int = 0) -> [[String: Any]] {
            guard depth < 6 else { return [] }
            if let array = value as? [[String: Any]] { return array }
            if let dictionary = value as? [String: Any] {
                for key in ["channels", "items", "rooms", "list", "data", "result"] {
                    if let nested = dictionary[key] {
                        let result = rows(nested, depth: depth + 1)
                        if !result.isEmpty { return result }
                    }
                }
                if dictionary["url"] != nil || dictionary["play_url"] != nil || dictionary["stream_url"] != nil { return [dictionary] }
            }
            return []
        }
        var output: [LiveItem] = []
        for row in rows(object).prefix(maximumChannels) {
            let text = ["url", "play_url", "stream_url", "hls_url", "room_url"].compactMap { row[$0] as? String }.first ?? ""
            guard let url = resolvedURL(text, baseURL: baseURL) else { continue }
            let name = ["name", "title", "anchor_name", "nickname"].compactMap { row[$0] as? String }.first ?? ""
            let group = (row["group"] as? String) ?? (row["platform_name"] as? String) ?? ""
            let kind = (row["kind"] as? String).flatMap(LinkKind.init(rawValue:))
            output.append(LiveItem(name: name, url: url, kind: kind, group: group))
        }
        return try deduplicate(output)
    }

    private static func deduplicate(_ items: [LiveItem]) throws -> [LiveItem] {
        var seen = Set<String>()
        let result = items.filter { seen.insert($0.id).inserted }
        guard !result.isEmpty else { throw LiveError.noItems }
        return result
    }
}

enum PlaylistFetcher {
    static func load(_ url: URL) async throws -> [LiveItem] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("LiveIOS/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, audio/x-mpegurl, application/vnd.apple.mpegurl, text/plain, */*", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LiveError.invalidURL }
        guard (200..<300).contains(http.statusCode) else { throw LiveError.http(http.statusCode) }
        guard response.expectedContentLength <= PlaylistParser.maximumBytes else { throw LiveError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < PlaylistParser.maximumBytes else { throw LiveError.tooLarge }
            data.append(byte)
        }
        return try PlaylistParser.parse(data, baseURL: response.url ?? url)
    }
}
