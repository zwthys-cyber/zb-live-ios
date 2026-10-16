import Foundation

enum HLSRewriter {
    /// Keep the sharpest video variant and the audio group it references.
    /// Media playlists lose low-latency partials so AVPlayer can play the full segments.
    static func rewrite(_ playlist: String, base: URL, translate: (URL) -> String) -> String {
        let normalized = playlist.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) {
            return rewriteMaster(lines, base: base, translate: translate)
        }
        return rewriteMedia(lines, base: base, translate: translate)
    }

    static func resolve(_ reference: String, base: URL) -> URL? {
        if let absolute = URL(string: reference), absolute.scheme != nil { return absolute }
        return URL(string: reference, relativeTo: base)?.absoluteURL
    }

    static func pixels(_ info: String) -> Int {
        guard let raw = attribute(info, key: "RESOLUTION") else { return 0 }
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return 0 }
        return width * height
    }

    static func bandwidth(_ info: String) -> Int {
        guard let raw = attribute(info, key: "BANDWIDTH"), let value = Int(raw) else { return 0 }
        return value
    }

    static func attribute(_ line: String, key: String) -> String? {
        var search = line[...]
        let token = key + "="
        while let range = search.range(of: token) {
            let before = range.lowerBound == line.startIndex ? nil : line[line.index(before: range.lowerBound)]
            if before == nil || before == "," || before == ":" || before == " " {
                var value = line[range.upperBound...]
                if value.first == "\"" {
                    value = value.dropFirst()
                    guard let end = value.firstIndex(of: "\"") else { return nil }
                    return String(value[..<end])
                }
                if let end = value.firstIndex(of: ",") { return String(value[..<end]) }
                return String(value)
            }
            search = line[range.upperBound...]
        }
        return nil
    }

    private static func isVideo(_ info: String) -> Bool {
        guard let codecs = attribute(info, key: "CODECS")?.lowercased() else { return true }
        return ["avc1", "hvc1", "hev1", "av01", "vp09", "dvh1"].contains { codecs.contains($0) }
    }

    private static func rewriteMaster(_ lines: [String], base: URL, translate: (URL) -> String) -> String {
        var variants: [(info: String, uri: String)] = []
        var media: [String] = []
        var version = "#EXT-X-VERSION:3"
        var independent = false
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                var next = index + 1
                while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
                if next < lines.count, !lines[next].hasPrefix("#") {
                    variants.append((line, lines[next]))
                    index = next + 1
                    continue
                }
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                media.append(line)
            } else if line.hasPrefix("#EXT-X-VERSION:") {
                version = line
            } else if line.hasPrefix("#EXT-X-INDEPENDENT-SEGMENTS") {
                independent = true
            }
            index += 1
        }
        let video = variants.filter { isVideo($0.info) }
        let choices = video.isEmpty ? variants : video
        guard let best = choices.max(by: { lhs, rhs in
            let left = (pixels(lhs.info), bandwidth(lhs.info))
            let right = (pixels(rhs.info), bandwidth(rhs.info))
            return left < right
        }) else { return rewriteMedia(lines, base: base, translate: translate) }
        var output = ["#EXTM3U", version]
        if independent { output.append("#EXT-X-INDEPENDENT-SEGMENTS") }
        if let group = attribute(best.info, key: "AUDIO") {
            for line in media where attribute(line, key: "GROUP-ID") == group {
                output.append(rewriteAttributes(line, base: base, translate: translate))
            }
        }
        output.append(best.info)
        let reference = best.uri.trimmingCharacters(in: .whitespaces)
        if let url = resolve(reference, base: base) { output.append(translate(url)) }
        else { output.append(reference) }
        return output.joined(separator: "\n") + "\n"
    }

    private static let lowLatencyPrefixes = [
        "#EXT-X-PART:", "#EXT-X-PRELOAD-HINT:", "#EXT-X-PART-INF:", "#EXT-X-SERVER-CONTROL:",
        "#EXT-X-SKIP:", "#EXT-X-RENDITION-REPORT:", "#EXT-X-DATERANGE:"
    ]

    private static func rewriteMedia(_ lines: [String], base: URL, translate: (URL) -> String) -> String {
        let stripped = lines.filter { line in !lowLatencyPrefixes.contains { line.hasPrefix($0) } }
        let source = stripped.contains(where: { $0.hasPrefix("#EXTINF:") }) ? stripped : lines
        return source.map { line in
            let rewritten = rewriteAttributes(line, base: base, translate: translate)
            let trimmed = rewritten.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let url = resolve(trimmed, base: base) else { return rewritten }
            return translate(url)
        }.joined(separator: "\n") + "\n"
    }

    private static func rewriteAttributes(_ line: String, base: URL, translate: (URL) -> String) -> String {
        var result = ""
        var rest = Substring(line)
        while let range = rest.range(of: "URI=\"") {
            result += rest[..<range.upperBound]
            rest = rest[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return result + rest }
            let raw = String(rest[..<end])
            if let url = resolve(raw, base: base) { result += translate(url) } else { result += raw }
            result.append("\"")
            rest = rest[rest.index(after: end)...]
        }
        result += rest
        return result
    }
}
