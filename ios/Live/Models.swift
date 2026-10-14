import Foundation
import CryptoKit

enum LinkKind: String, Codable, CaseIterable, Sendable {
    case web
    case media

    var label: String { self == .web ? "网页观看" : "视频播放" }

    static func detect(_ url: URL) -> LinkKind {
        let file = url.pathExtension.lowercased()
        return ["m3u8", "mp4", "m4v", "mov", "mp3", "aac"].contains(file) ? .media : .web
    }
}

struct LiveItem: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var url: URL
    var kind: LinkKind
    var group: String

    var id: String { SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() }
    var host: String { url.host ?? "" }

    init(name: String, url: URL, kind: LinkKind? = nil, group: String = "") {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (url.host ?? "直播") : name
        self.url = url
        self.kind = kind ?? LinkKind.detect(url)
        self.group = group
    }
}

struct WatchRecord: Codable, Identifiable, Hashable, Sendable {
    var item: LiveItem
    var date: Date
    var id: String { item.id }
}

struct LibrarySnapshot: Codable {
    var favorites: [LiveItem] = []
    var channels: [LiveItem] = []
    var subscriptions: [Subscription] = []
    var history: [WatchRecord] = []
    var backgroundAudio = false
}

struct Subscription: Codable, Identifiable, Hashable, Sendable {
    var url: URL
    var name: String
    var updated: Date
    var id: String { url.absoluteString }
}

enum LiveError: LocalizedError {
    case invalidURL, noItems, hlsPlaylist, unsupportedScheme, tooLarge, invalidJSON, tooManyChannels
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入完整的 http:// 或 https:// 链接。"
        case .unsupportedScheme: return "目前支持 HTTP / HTTPS 网页和视频链接。RTMP、FLV 等需使用平台网页观看。"
        case .noItems: return "没有找到可用频道。支持 M3U 频道列表、JSON 列表和每行一个链接的文本。"
        case .hlsPlaylist: return "这是 HLS 播放清单，请在「打开链接」中直接播放此地址。"
        case .tooLarge: return "频道列表超过 5 MB，请使用较小的文件。"
        case .invalidJSON: return "JSON 格式无法识别。每个频道需要名称和 HTTP / HTTPS 地址。"
        case .tooManyChannels: return "保存后的频道总数将超过 5000 个。请先移除部分频道，或清空旧列表后重试。"
        case .http(let status): return "服务器返回 HTTP \(status)，请检查地址或在平台网页内登录。"
        }
    }
}

enum LinkValidator {
    static func parse(_ input: String) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              var parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), !((parts.host ?? "").isEmpty),
              parts.user == nil, parts.password == nil else { throw LiveError.invalidURL }
        guard ["http", "https"].contains(scheme) else { throw LiveError.unsupportedScheme }
        parts.scheme = scheme
        parts.host = parts.host?.lowercased()
        guard let url = parts.url else { throw LiveError.invalidURL }
        return url
    }
}

enum Platforms {
    // Names and homepage addresses present in the recovered APK. These are website entries,
    // not recovered native room-list APIs. No account tokens or Android tunnels are embedded.
    static let all: [LiveItem] = [
        ("Stripchat", "https://stripchat.com/"),
        ("BIGO LIVE", "https://www.bigo.tv/"),
        ("Chaturbate", "https://chaturbate.com/"),
        ("BongaCams", "https://bongacams.com/"),
        ("CAM4", "https://www.cam4.com/"),
        ("CamSoda", "https://www.camsoda.com/"),
        ("Flirt4Free", "https://www.flirt4free.com/")
    ].compactMap { name, text in
        guard let url = try? LinkValidator.parse(text) else { return nil }
        return LiveItem(name: name, url: url, kind: .web, group: "平台")
    }
}
