import Foundation
import CryptoKit

enum StripchatPlaybackError: LocalizedError, Equatable {
    case noVariant, unknownScheme, invalidSegment, unavailable

    var errorDescription: String? {
        switch self {
        case .noVariant: return "SC 暂未提供可用的原画直播线路。"
        case .unknownScheme: return "SC 已更新播放协议，请更新应用后重试。"
        case .invalidSegment: return "SC 视频地址解析失败，请重新连接。"
        case .unavailable: return "SC 未返回有效直播内容，房间可能已下播或切换为收费／私密状态。"
        }
    }
}

enum StripchatPlayback {
    static let origins = ["https://edge-hls.doppiocdn.com", "https://edge-hls.doppiocdn.net"].compactMap(URL.init(string:))

    static func streams(from data: [String: Any], origins: [URL] = StripchatPlayback.origins) -> [StreamCandidate]? {
        let code = (data["platform_code"] as? String ?? "").lowercased()
        guard code.hasPrefix("sc_") || code == "stripchat" else { return nil }
        let id = data["chat_room_id"].map { String(describing: $0) }
            ?? (data["id"] as? String)?.split(separator: "_").last.map(String.init)
        guard let id, validID(id) else { return [] }
        return origins.map { StreamCandidate(url: master(id: id, origin: $0), kind: .stripchat) }
    }

    static func master(id: String, origin: URL) -> URL {
        origin.appendingPathComponent("hls/\(id)/master/\(id)_auto.m3u8")
    }

    /// Also recognizes pasted original CDN links. No arbitrary relay host is promoted.
    static func originalMaster(for url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              ["doppiocdn.com", "doppiocdn.net", "doppiocdn.org", "doppiocdn.media", "doppiocdn.live", "saawsedge.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        let parts = url.pathComponents
        guard let marker = parts.firstIndex(where: { $0 == "hls" || $0.hasPrefix("b-hls-") }), parts.count > marker + 1 else { return nil }
        let id = parts[marker + 1]
        guard validID(id), let origin = origins.first else { return nil }
        if host.hasPrefix("edge-hls.doppiocdn."), marker + 2 < parts.count, parts[marker + 2] == "master",
           let currentOrigin = URL(string: "https://\(host)") {
            return master(id: id, origin: currentOrigin)
        }
        return master(id: id, origin: origin)
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32 && id.utf8.allSatisfy { (48...57).contains($0) }
    }
}

/// Public player protocol descriptors, not user credentials. See docs/SC-PLAYBACK.md.
/// Negotiate only a descriptor that the current master actually advertises.
enum MouflonPlaylist {
    struct Scheme: Equatable, Sendable {
        let version: String
        let keyID: String
    }

    static let publicKeys: [String: String] = [
        "Zokee2OhPh9kugh4": "Quean4cai9boJa5a",
        "Zeechoej4aleeshi": "ubahjae7goPoodi6",
        "Ook7quaiNgiyuhai": "EQueeGh2kaewa3ch",
        "Fq6m2TO2ZeBkRPm9": "xb6di1NF9EFXHUwb",
        "GrRncsoByZmsiT6L": "NigHYyOD9l4rvAEb",
        "1Dzcc6OjP73LKbtI": "Y64UVwX5RrIWnOLp",
        "N2oLovTIXb0o28Uj": "ABE7Sj8jh3oPM2ae",
        "NTK9aqcLmNFMWrpQ": "tOcYOap4Ty1l9Jzb",
        "7uUnbD0jMCB9GH32": "lzCQ6QBTnLpB0zMF",
        "Ohi7eTRBpkAuML0l": "kExe29N2sLFrHGqu",
        "OLzu7QlySkG2fVRn": "CsovScFH9VirSJ4Z"
    ]
    static let fixtureKeys = ["fixture-key": "fixture-public-decode-key", "fixture-rotated-key": "fixture-rotated-decode-key"]

    static func schemes(in playlist: String) -> [Scheme] {
        lines(playlist).compactMap { line in
            let prefix = "#EXT-X-MOUFLON:PSCH:"
            guard line.hasPrefix(prefix) else { return nil }
            let parts = line.dropFirst(prefix.count).split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, ["v1", "v2"].contains(parts[0]) else { return nil }
            return Scheme(version: parts[0], keyID: parts[1])
        }
    }

    static func negotiate(_ playlist: String, keys: [String: String]) throws -> Scheme? {
        try rejectAdvertisement(playlist)
        let choices = schemes(in: playlist)
        if let scheme = choices.first(where: { keys[$0.keyID] != nil }) { return scheme }
        if playlist.contains("#EXT-X-MOUFLON") { throw StripchatPlaybackError.unknownScheme }
        return nil
    }

    static func applying(_ scheme: Scheme?, to url: URL) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw StripchatPlaybackError.invalidSegment }
        guard let scheme else { return url }
        var query = (parts.queryItems ?? []).filter { !["psch", "pkey"].contains($0.name) }
        query += [URLQueryItem(name: "psch", value: scheme.version), URLQueryItem(name: "pkey", value: scheme.keyID)]
        parts.queryItems = query
        guard let result = parts.url else { throw StripchatPlaybackError.invalidSegment }
        return result
    }

    static func decode(_ playlist: String, base: URL, keys: [String: String]) throws -> String {
        let scheme = try negotiate(playlist, keys: keys)
        let key = scheme.flatMap { keys[$0.keyID] }
        var pending: String?
        var output: [String] = []
        for line in lines(playlist) {
            if line.hasPrefix("#EXT-X-MOUFLON:PSCH:") { continue }
            if line.hasPrefix("#EXT-X-MOUFLON:URI:") {
                guard pending == nil, scheme?.version == "v2", let key else { throw StripchatPlaybackError.invalidSegment }
                let uri = String(line.dropFirst("#EXT-X-MOUFLON:URI:".count))
                var parts = uri.components(separatedBy: "_")
                guard parts.count >= 3 else { throw StripchatPlaybackError.invalidSegment }
                let index = parts.count - 2
                parts[index] = try decodeToken(String(parts[index].reversed()), key: key)
                pending = try checkedURL(parts.joined(separator: "_"), base: base).absoluteString
                continue
            }
            if line.hasPrefix("#EXT-X-MOUFLON:FILE:") {
                guard pending == nil, scheme?.version == "v1", let key else { throw StripchatPlaybackError.invalidSegment }
                pending = try decodeToken(String(line.dropFirst("#EXT-X-MOUFLON:FILE:".count)), key: key, filename: true)
                continue
            }
            if line.hasPrefix("#EXT-X-MOUFLON") { throw StripchatPlaybackError.unknownScheme }
            if !line.isEmpty, !line.hasPrefix("#") {
                let url = try checkedURL(line, base: base)
                if url.lastPathComponent == "media.mp4" {
                    guard let decoded = pending else { throw StripchatPlaybackError.invalidSegment }
                    if scheme?.version == "v1" {
                        output.append(try checkedURL(url.deletingLastPathComponent().appendingPathComponent(decoded).absoluteString, base: base).absoluteString)
                    } else { output.append(decoded) }
                    pending = nil
                    continue
                }
                guard pending == nil else { throw StripchatPlaybackError.invalidSegment }
            }
            output.append(line)
        }
        guard pending == nil else { throw StripchatPlaybackError.invalidSegment }
        return output.joined(separator: "\n") + "\n"
    }

    static func rejectAdvertisement(_ playlist: String) throws {
        guard !playlist.uppercased().contains("#EXT-X-MOUFLON-ADVERT") else { throw StripchatPlaybackError.unavailable }
    }

    private static func decodeToken(_ token: String, key: String, filename: Bool = false) throws -> String {
        let normalized = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !normalized.isEmpty, normalized.count <= 4096,
              let encrypted = Data(base64Encoded: normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)) else { throw StripchatPlaybackError.invalidSegment }
        let digest = Array(SHA256.hash(data: Data(key.utf8)))
        let plain = Data(encrypted.enumerated().map { $0.element ^ digest[$0.offset % digest.count] })
        guard let decoded = String(data: plain, encoding: .utf8), !decoded.isEmpty, decoded.count <= 256,
              decoded.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || (filename && ($0 == 46 || $0 == 95)) }),
              decoded != ".", decoded != ".." else { throw StripchatPlaybackError.invalidSegment }
        return decoded
    }

    private static func checkedURL(_ reference: String, base: URL) throws -> URL {
        guard let url = HLSRewriter.resolve(reference, base: base),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == base.host?.lowercased(), url.port == base.port,
              url.user == nil, url.password == nil,
              !reference.contains("\r"), !reference.contains("\n") else { throw StripchatPlaybackError.invalidSegment }
        return url
    }

    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
