import Foundation

enum HLSRewriter {
    struct Variant {
        let info: String
        let url: URL
    }

    /// Inspect declared variants, including portrait/source and resolutions above 1080p.
    static func highestVariant(in playlist: String, base: URL) -> Variant? {
        let lines = playlist.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var variants: [Variant] = []
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
            guard index + 1 < lines.count, !lines[index + 1].hasPrefix("#"),
                  let url = resolve(lines[index + 1], base: base) else { continue }
            variants.append(Variant(info: line, url: url))
        }
        let video = variants.filter { isVideo($0.info) }
        return (video.isEmpty ? variants : video).max {
            (pixels($0.info), bandwidth($0.info)) < (pixels($1.info), bandwidth($1.info))
        }
    }

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

    /// 1080p. At or above this, another playlist is not worth the extra wait.
    static let hdThreshold = 1920 * 1080

    /// Largest declared frame, or a resolution hint written into a single media playlist.
    static func sharpness(_ playlist: String) -> Int {
        let normalized = playlist.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let infos = lines.filter { $0.hasPrefix("#EXT-X-STREAM-INF:") }
        if !infos.isEmpty {
            let frame = infos.map(pixels).max() ?? 0
            if frame > 0 { return frame }
            return (infos.map(bandwidth).max() ?? 0) / 8
        }
        return hintedPixels(normalized)
    }

    /// Encrypted or custom-container playlists are not a safe replacement for a clear one.
    static func isDirectlyPlayable(_ playlist: String) -> Bool {
        let upper = playlist.uppercased()
        guard upper.contains("#EXTM3U") else { return false }
        if upper.contains("MOUFLON") { return false }
        if upper.contains("METHOD=AES") || upper.contains("METHOD=SAMPLE") { return false }
        return true
    }

    /// Higher renditions and the adaptive `auto` playlist on the same address.
    static func upgradeURLs(for url: URL) -> [URL] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        if let path = replacements(in: components.percentEncodedPath) {
            return path.compactMap { value in
                var copy = components
                copy.percentEncodedPath = value
                return copy.url
            }
        }
        guard let query = components.percentEncodedQuery, let replaced = replacements(in: query) else { return [] }
        return replaced.compactMap { value in
            var copy = components
            copy.percentEncodedQuery = value
            return copy.url
        }
    }

    private static func replacements(in text: String) -> [String]? {
        let pattern = "(?i)(?:^|(?<=[/_.:=-]))(144|240|360|480|540|576|720|960|1080|1440|2160)(p)?(?=$|[/_.?&#=-])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let full = Range(match.range, in: text),
              let number = Range(match.range(at: 1), in: text),
              let height = Int(text[number]) else { return nil }
        let hasP = Range(match.range(at: 2), in: text) != nil
        var tokens: [String] = []
        for target in [1080, 720, 1440] where target > height {
            tokens.append(hasP ? "\(target)p" : "\(target)")
        }
        tokens.append("auto")
        var seen = Set<String>()
        var results: [String] = []
        for token in tokens {
            var copy = text
            copy.replaceSubrange(full, with: token)
            if copy != text, seen.insert(copy).inserted { results.append(copy) }
        }
        return results.isEmpty ? nil : results
    }

    private static func hintedPixels(_ text: String) -> Int {
        var best = 0
        let framed = "(?i)(\\d{2,4})x(\\d{2,4})"
        if let regex = try? NSRegularExpression(pattern: framed) {
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let width = Int(ns.substring(with: match.range(at: 1))) ?? 0
                let height = Int(ns.substring(with: match.range(at: 2))) ?? 0
                guard width >= 16, height >= 16, width <= 7680, height <= 4320 else { continue }
                best = max(best, width * height)
            }
        }
        if best > 0 { return best }
        let named = "(?i)(?:^|(?<=[/_.:=-]))(144|240|360|480|540|576|720|960|1080|1440|2160)p?(?=$|[/_.?&#=-])"
        guard let regex = try? NSRegularExpression(pattern: named) else { return 0 }
        let ns = text as NSString
        let known = [144: 192 * 144, 240: 426 * 240, 360: 640 * 360, 480: 854 * 480, 540: 960 * 540, 576: 1024 * 576, 720: 1280 * 720, 960: 1280 * 960, 1080: 1920 * 1080, 1440: 2560 * 1440, 2160: 3840 * 2160]
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let height = Int(ns.substring(with: match.range(at: 1))) ?? 0
            best = max(best, known[height] ?? 0)
        }
        return best
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
