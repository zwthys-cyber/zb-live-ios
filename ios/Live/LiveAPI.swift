import Foundation
import CryptoKit
import Security
import CommonCrypto

struct LiveAPIConfiguration: Sendable {
    var bases: [URL]
    var publicKeyDER: Data
    var stripchatOrigins: [URL] = StripchatPlayback.origins
    static let production = LiveAPIConfiguration(
        bases: ["https://cbg.saaafcsdafvsdgredhdfbxcvxzcvsds.xyz", "https://cbg.saxcvcvnmliotergsdfsdv.xyz"].compactMap(URL.init(string:)),
        publicKeyDER: Data(base64Encoded: "MIIBCgKCAQEAn3e54Fm9rWz7GLQx50UpQEtZeylR/eATPCq32CG8WPqkI0s6+vQmyXCpYGl6QYZScGghl0/HBwrMcBwb4ea6LQw3YpQ0lYA2TT8WnvCF9gYnCcytzhL1EjdTmwWeSmQ6DTPpSUsmb1ZDaa2CVvs9z/ExiuQiqXsfiUfFmzBxrb07UXcorBNXK8TUSdNK7arxEldnxv6SG9knZkPs52LSCu0pHB2QVQlC4IkVIUFyVwQcQh6qXKchXf59e3DPaqIgukirg/6mZYVAgboh9DRAp326qcRTTnEjJIFReULntVqkOsvePfbOwmxoUuWaXXdPfn/Cg/goY1NsocLqX5MYLQIDAQAB")!)
    // This public key has a matching, deliberately public test key in tests/Fixtures.
    static let fixture: LiveAPIConfiguration = {
        var value = LiveAPIConfiguration(bases: [URL(string: "http://127.0.0.1:8765")!], publicKeyDER: Data(base64Encoded: "MIIBCgKCAQEA8KPa5oS8mltFx2efgND/udZHIH3aevrcDJAJvRg7LWRX8Xcl2Wcn2M/y7QsX2gxZp2CsudvIdfDLOnBlmVDr+GSWzPFuwy/pwePjp7I+wiYfXCHIIH1aVFT08Qo8BvVaQoYbQjOcHGy1rnsOzMG0tlcyD+mq56HRTDmUc3+fruApaOsPEB6nVbm77jIwWfBCbpjzSqNn5DtWScNlQ1w2h3elLLA8Vrz+Bk8j00kiV/IB72mOMXStBXu2Vc8xS/bY/AtIXd872zeyhaXvrT7LzexC+VRRntWUuT/wSB0V8/jjuXFfTfb3qCPFvu1slIFjgDPWr0qSHaOKLoY1AozMkwIDAQAB")!)
        value.stripchatOrigins = [URL(string: "http://127.0.0.1:8765/sc")!]
        return value
    }()
}

enum LiveAPIError: LocalizedError {
    case invalidResponse, cryptography, invalidSignature, server(Int, String), noStream
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "直播服务返回的数据无法识别，请稍后刷新。"
        case .cryptography: return "直播连接初始化失败，请重试。"
        case .invalidSignature: return "直播数据校验失败，请刷新后重试。"
        case .server(_, let message): return message.isEmpty ? "直播服务暂时不可用。" : message
        case .noStream: return "此房间暂未提供兼容的播放线路，请选择其他房间。"
        }
    }
}

// Protocol constants recovered from the supplied APK; these are client material,
// not an account password or an embedded user's access token.
enum LiveAPICrypto {
    static let signSecret = Data("HtxDnCtl7ePUvZU9SE0tfDSjR".utf8)
    static let key = Data("Dn7kQp2mXw9sL4aR".utf8)
    static let iv = Data("u8hE3nBqK1zT6cYf".utf8)

    static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw LiveAPIError.cryptography }
        return Data(bytes)
    }
    static func hmac(_ data: Data) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: signSecret))).base64EncodedString()
    }
    static func signature(route: String, timestamp: String, nonce: String) -> String {
        hmac(Data("dongni\n\(route)\n\(timestamp)\n\(nonce)".utf8))
    }
    static func wrap(_ key: Data, publicKeyDER: Data) throws -> String {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits: 2048]
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCreateWithData(publicKeyDER as CFData, attributes as CFDictionary, &error),
              let encrypted = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA256, key as CFData, &error) else { throw LiveAPIError.cryptography }
        return (encrypted as Data).base64EncodedString()
    }
    static func base64URL(_ text: String) throws -> Data {
        let normalized = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)) else { throw LiveAPIError.invalidResponse }
        return data
    }
    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard [16, 24, 32].contains(key.count), iv.count == 16, !data.isEmpty, data.count % 16 == 0 else { throw LiveAPIError.cryptography }
        let capacity = data.count + kCCBlockSizeAES128
        var result = Data(count: capacity), written = 0
        let status = result.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { secret in
                    iv.withUnsafeBytes { vector in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), secret.baseAddress, key.count, vector.baseAddress, input.baseAddress, data.count, output.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw LiveAPIError.cryptography }
        result.count = written
        return result
    }
    static func decode(_ response: Data, sessionKey: Data) throws -> [String: Any] {
        guard let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any] else { throw LiveAPIError.invalidResponse }
        guard let mode = envelope["enc"] as? Int, mode != 0 else { return envelope }
        guard let payload = envelope["payload"] as? String else { throw LiveAPIError.invalidResponse }
        let encrypted = try base64URL(payload)
        let plain: Data
        if mode == 1 { plain = try decrypt(encrypted, key: key, iv: iv) }
        else if mode == 2, encrypted.count > 16 { plain = try decrypt(Data(encrypted.dropFirst(16)), key: sessionKey, iv: Data(encrypted.prefix(16))) }
        else { throw LiveAPIError.invalidResponse }
        guard var decoded = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw LiveAPIError.invalidResponse }
        if let signature = decoded["sign"] as? String, !signature.isEmpty {
            guard let data = rawField("data", in: plain), hmac(data) == signature else { throw LiveAPIError.invalidSignature }
        }
        decoded["code"] = envelope["code"] ?? 0
        return decoded
    }
    // Preserve the server's JSON object order for its HMAC. Foundation dictionaries
    // reorder keys. Strings, escapes and nested values are scanned as JSON tokens.
    static func rawField(_ name: String, in data: Data) -> Data? {
        let b = Array(data)
        var i = 0
        func skipWhitespace() { while i < b.count, [9, 10, 13, 32].contains(b[i]) { i += 1 } }
        func stringEnd(_ start: Int) -> Int? {
            var cursor = start + 1, escaped = false
            while cursor < b.count {
                if escaped { escaped = false }
                else if b[cursor] == 92 { escaped = true }
                else if b[cursor] == 34 { return cursor + 1 }
                cursor += 1
            }
            return nil
        }
        skipWhitespace()
        guard i < b.count, b[i] == 123 else { return nil }
        i += 1
        while i < b.count {
            skipWhitespace()
            guard i < b.count, b[i] == 34, let end = stringEnd(i),
                  let field = try? JSONSerialization.jsonObject(with: Data(b[i..<end]), options: .fragmentsAllowed) as? String else { return nil }
            i = end; skipWhitespace()
            guard i < b.count, b[i] == 58 else { return nil }
            i += 1; skipWhitespace()
            let start = i
            var depth = 0
            while i < b.count {
                if b[i] == 34 { guard let end = stringEnd(i) else { return nil }; i = end; continue }
                if b[i] == 91 || b[i] == 123 { depth += 1 }
                else if b[i] == 93 || b[i] == 125 { if depth == 0 { break }; depth -= 1 }
                else if b[i] == 44 && depth == 0 { break }
                i += 1
            }
            if field == name {
                var compact = [UInt8](), quoted = false, escaped = false
                for byte in b[start..<i] {
                    if quoted {
                        compact.append(byte)
                        if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
                    } else if byte == 34 { quoted = true; compact.append(byte) }
                    else if ![9, 10, 13, 32].contains(byte) { compact.append(byte) }
                }
                return Data(compact)
            }
            guard i < b.count, b[i] == 44 else { return nil }
            i += 1
        }
        return nil
    }
}

struct RemotePlatform: Identifiable, Hashable, Sendable {
    let id: String, name: String, code: String
    let image: URL?
    let online: Int
    init?(_ data: [String: Any]) {
        guard let id = data["id"], let name = data["name"] as? String else { return nil }
        self.id = String(describing: id); self.name = name
        code = data["platform_code"] as? String ?? ""
        image = (data["img"] as? String).flatMap(URL.init(string:))
        online = (data["online_num"] as? Int) ?? Int(data["online_num"] as? String ?? "") ?? 0
    }
}
struct RemoteRoom: Identifiable, Sendable {
    let id: String, name: String
    let image: URL?
    let online: Int
    let media: URL?
    init?(_ data: [String: Any]) {
        guard let rawID = data["id"] else { return nil }
        id = String(describing: rawID)
        name = data["name"] as? String ?? "直播间"
        image = (["image", "cover", "img"].compactMap { data[$0] as? String }.first { !$0.isEmpty }).flatMap(URL.init(string:))
        online = data["watched"] as? Int ?? 0
        media = (data["cdn_hls_url"] as? String).flatMap { try? LinkValidator.parse($0) }
    }
    func item(platform: RemotePlatform, fallback: URL) -> LiveItem {
        LiveItem(name: name, url: media ?? fallback, kind: .media, group: platform.name, roomID: id)
    }
}

enum PlaybackPlan {
    static let clientVersion = "1.1.14"
    static let clientBuild = "124"

    static func streams(from data: [String: Any]) -> [StreamCandidate] {
        var result: [StreamCandidate] = []
        func add(_ raw: String?, kind: StreamKind?) {
            guard let raw, !raw.isEmpty, let url = try? LinkValidator.parse(raw) else { return }
            guard !result.contains(where: { $0.url == url }) else { return }
            result.append(StreamCandidate(url: url, kind: kind ?? StreamKind.classify(url) ?? .hls))
        }
        for key in ["cdn_hls_url", "hls_url", "play_url", "url"] { add(data[key] as? String, kind: nil) }
        add(data["flv_url"] as? String, kind: .flv)
        if let relay = data["rtmp_url"] as? String, relay.hasPrefix("http://") || relay.hasPrefix("https://") { add(relay, kind: .flv) }
        return result
    }

    /// Edge relays wrap the real playlist in `u`. A forbidden relay can still be played from that address.
    static func embeddedStream(_ url: URL) -> URL? {
        guard let query = url.query else { return nil }
        for part in query.split(separator: "&") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard pair.count == 2, pair[0] == "u" else { continue }
            let value = pair[1].removingPercentEncoding ?? pair[1]
            guard let nested = URL(string: value), let scheme = nested.scheme?.lowercased(), ["http", "https"].contains(scheme), nested.host != nil else { return nil }
            return nested
        }
        return nil
    }
}

actor LiveAPI {
    static let shared = LiveAPI(configuration: ProcessInfo.processInfo.arguments.contains("--ui-testing") ? .fixture : .production)
    let configuration: LiveAPIConfiguration
    private let session: URLSession
    private let device: String
    private var transportKey: Data?
    private var publicEnvelope: String?
    private var ticket = "", token = ""
    private var expires: TimeInterval = 0
    private var refreshing: Task<Void, Error>?

    init(configuration: LiveAPIConfiguration, session: URLSession = .shared, device: String? = nil) {
        self.configuration = configuration; self.session = session
        let saved = device ?? UserDefaults.standard.string(forKey: "live.api.device") ?? ""
        if saved.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil { self.device = saved }
        else {
            let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            self.device = generated
            if device == nil { UserDefaults.standard.set(generated, forKey: "live.api.device") }
        }
    }
    private func ensureSession() async throws {
        if !token.isEmpty, expires > Date().timeIntervalSince1970 + 90 { return }
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.refreshSession() }
        refreshing = task
        defer { refreshing = nil }
        try await task.value
    }
    private func refreshSession() async throws {
        if transportKey == nil {
            let key = try LiveAPICrypto.random(16)
            publicEnvelope = try LiveAPICrypto.wrap(key, publicKeyDER: configuration.publicKeyDER)
            transportKey = key
        }
        _ = try await request("app_version")
        let result = try await request("live/session", params: ["device_id": device])
        guard let data = result["data"] as? [String: Any], let session = data["token"] as? String, !session.isEmpty else { throw LiveAPIError.invalidResponse }
        token = session
        expires = (data["expire"] as? NSNumber)?.doubleValue ?? Double(data["expire"] as? String ?? "") ?? Date().timeIntervalSince1970 + 300
    }
    func platforms() async throws -> [RemotePlatform] {
        try await ensureSession()
        let response = try await authenticated("live/platforms")
        guard let data = response["data"] as? [String: Any], let rows = data["platforms"] as? [[String: Any]] else { throw LiveAPIError.invalidResponse }
        return rows.compactMap(RemotePlatform.init)
    }
    func rooms(platformID: String) async throws -> [RemoteRoom] {
        try await ensureSession()
        let response = try await authenticated("live/rooms", params: ["platform_id": platformID, "limit": "2000"])
        guard let data = response["data"] as? [String: Any], let rows = data["rooms"] as? [[String: Any]] else { throw LiveAPIError.invalidResponse }
        return rows.compactMap(RemoteRoom.init)
    }
    func playback(_ item: LiveItem) async throws -> LiveItem {
        guard let id = item.roomID else { return item }
        try await ensureSession()
        let response = try await authenticated("live/play", params: ["id": id])
        guard let data = response["data"] as? [String: Any] else { throw LiveAPIError.invalidResponse }
        // The original service wraps HLS through live/hls; resolve a fresh URL on
        // every open, including a saved favorite whose earlier stream expired.
        let scStreams = StripchatPlayback.streams(from: data, origins: configuration.stripchatOrigins)
        let streams = scStreams ?? PlaybackPlan.streams(from: data)
        guard let url = streams.first?.url else { throw LiveAPIError.noStream }
        var headers = data["headers"] as? [String: String] ?? [:]
        if let agent = data["user_agent"] as? String, !agent.isEmpty { headers["User-Agent"] = agent }
        if let referer = data["referer"] as? String, !referer.isEmpty { headers["Referer"] = referer }
        if scStreams != nil {
            headers["Origin"] = "https://stripchat.com"
            headers["Referer"] = "https://stripchat.com/"
        }
        return LiveItem(name: item.name, url: url, kind: .media, group: item.group, headers: headers.isEmpty ? nil : headers, roomID: id, streams: streams)
    }
    private func authenticated(_ route: String, params: [String: String] = [:]) async throws -> [String: Any] {
        do { return try await request(route, params: params) }
        catch LiveAPIError.server(401, _) {
            token = ""; expires = 0
            try await ensureSession()
            return try await request(route, params: params)
        }
    }
    private func request(_ route: String, params: [String: String] = [:]) async throws -> [String: Any] {
        var lastError: Error = LiveAPIError.invalidResponse
        for base in configuration.bases {
            try Task.checkCancellation()
            do {
                var url = URLComponents(url: base.appendingPathComponent("api.php"), resolvingAgainstBaseURL: false)!
                url.queryItems = [URLQueryItem(name: "r", value: route)] + params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
                guard let address = url.url else { throw LiveAPIError.invalidResponse }
                var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
                let timestamp = String(Int(Date().timeIntervalSince1970))
                let nonce = try LiveAPICrypto.random(16).map { String(format: "%02x", $0) }.joined()
                request.allHTTPHeaderFields = ["X-App-Id": "dongni", "X-App-Version": PlaybackPlan.clientVersion, "X-App-Build": PlaybackPlan.clientBuild, "User-Agent": "Dart/3.11 (dart:io)", "X-Timestamp": timestamp, "X-Nonce": nonce, "X-Sign": LiveAPICrypto.signature(route: route, timestamp: timestamp, nonce: nonce), "X-Device-Id": device]
                if let publicEnvelope { request.setValue(publicEnvelope, forHTTPHeaderField: "X-Session-PubEnc") }
                if !ticket.isEmpty { request.setValue(ticket, forHTTPHeaderField: "X-Access-Ticket") }
                if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-Live-Session") }
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw LiveAPIError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else { throw LiveError.http(http.statusCode) }
                if let ticket = http.value(forHTTPHeaderField: "X-Access-Ticket"), !ticket.isEmpty { self.ticket = ticket }
                var body = Data()
                for try await byte in bytes { body.append(byte); if body.count > 20 * 1024 * 1024 { throw LiveError.tooLarge } }
                let decoded = try LiveAPICrypto.decode(body, sessionKey: transportKey ?? Data())
                let code = decoded["code"] as? Int ?? Int(decoded["code"] as? String ?? "") ?? 0
                guard code == 0 || code == 200 else { throw LiveAPIError.server(code, decoded["msg"] as? String ?? "直播请求失败。") }
                return decoded
            } catch is CancellationError { throw CancellationError() }
            catch LiveAPIError.server(let code, let message) { throw LiveAPIError.server(code, message) }
            catch { lastError = error }
        }
        throw lastError
    }
}
