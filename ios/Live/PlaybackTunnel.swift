import Foundation
import Darwin

enum TunnelError: LocalizedError {
    case unavailable(Int), notPlaylist, unsupported, timeout
    var errorDescription: String? {
        switch self {
        case .unavailable(let code) where code > 0: return "直播线路返回 HTTP \(code)。"
        case .unavailable: return "直播线路暂时连不上。"
        case .notPlaylist: return "直播地址没有返回可播放的视频清单。"
        case .unsupported: return "这条线路的视频编码暂时无法播放。"
        case .timeout: return "直播线路连接超时。"
        }
    }
}

/// Local HTTP server that pins HLS to the sharpest variant and remuxes HTTP-FLV into HLS.
final class PlaybackTunnel: @unchecked Sendable {
    private let lock = NSLock()
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var port = 0
    private var listenFD: Int32 = -1
    private var stopped = false
    private var invalidated = false
    private var headers: [String: String] = [:]
    private var playlistSource: URL?
    private var playlistFinal: URL?
    private var warmed: Data?
    private let segmenter = FLVSegmenter()
    private var flvStatus: Int?
    private var flvError: Error?
    private var flvBytes = 0
    private var flvTask: URLSessionDataTask?
    private var streamSession: URLSession?
    private let playlistSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    private let pump = FLVPump()

    func open(_ candidate: StreamCandidate, headers: [String: String]) async throws -> URL {
        self.headers = headers
        try startServer()
        switch candidate.kind {
        case .flv:
            try await waitForFLV(candidate.url)
            return endpoint("live.m3u8")
        case .hls:
            let loaded = try await loadPlaylist(candidate.url, allowUnwrap: true)
            lock.lock()
            playlistSource = loaded.source
            playlistFinal = loaded.final
            warmed = loaded.data
            lock.unlock()
            return endpoint("root.m3u8")
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        let task = flvTask
        flvTask = nil
        let session = streamSession
        let shouldInvalidate = !invalidated
        invalidated = true
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        if shouldInvalidate { playlistSession.invalidateAndCancel() }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    private func startServer() throws {
        lock.lock()
        if listenFD >= 0 { lock.unlock(); return }
        lock.unlock()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TunnelError.unavailable(0) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7F000001).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else { close(fd); throw TunnelError.unavailable(0) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        lock.lock()
        port = Int(UInt16(bigEndian: actual.sin_port))
        listenFD = fd
        lock.unlock()
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            lock.lock()
            let halt = stopped
            lock.unlock()
            if halt { break }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, nfds_t(1), 200)
            if ready < 0 { break }
            if ready == 0 { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            var nosig: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout.size(ofValue: nosig)))
            var timeout = timeval(tv_sec: 20, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            Task { await self.respond(client) }
        }
    }

    deinit { stop() }

    private func endpoint(_ path: String) -> URL {
        lock.lock()
        let current = port
        lock.unlock()
        return URL(string: "http://127.0.0.1:\(current)/t/\(token)/\(path)")!
    }

    private func respond(_ fd: Int32) async {
        defer { close(fd) }
        guard let request = readHeaders(fd) else { return }
        let lines = request.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first?.split(separator: " ") , requestLine.count >= 2 else { return }
        let method = String(requestLine[0])
        let path = String(requestLine[1])
        let parts = path.split(separator: "?").first.map { String($0).split(separator: "/").map(String.init) } ?? []
        guard parts.count >= 3, parts[0] == "t", parts[1] == token else {
            write(fd, status: 404, type: "text/plain", body: Data("missing".utf8), head: method == "HEAD")
            return
        }
        let route = parts[2]
        do {
            if route == "live.m3u8" {
                let playlist = lock.sync { Data(segmenter.playlist().utf8) }
                write(fd, status: 200, type: "application/vnd.apple.mpegurl", body: playlist, head: method == "HEAD", header: request)
            } else if route == "seg", parts.count >= 4, let index = Int(parts[3].replacingOccurrences(of: ".ts", with: "")) {
                let data = lock.sync { segmenter.segment(at: index) }
                guard let data else {
                    write(fd, status: 404, type: "text/plain", body: Data("missing segment".utf8), head: method == "HEAD")
                    return
                }
                write(fd, status: 200, type: "video/MP2T", body: data, head: method == "HEAD", header: request)
            } else if route == "root.m3u8" {
                let playlist = try await currentPlaylist()
                write(fd, status: 200, type: "application/vnd.apple.mpegurl", body: Data(playlist.utf8), head: method == "HEAD", header: request)
            } else if route == "p", parts.count >= 4, let upstream = decode(parts[3]) {
                let (data, http) = try await fetch(upstream)
                guard (200..<300).contains(http.statusCode) else { throw TunnelError.unavailable(http.statusCode) }
                let final = http.url ?? upstream
                if Self.isPlaylist(data, mime: http.mimeType) {
                    let text = String(decoding: data, as: UTF8.self)
                    let rewritten = HLSRewriter.rewrite(text, base: final) { self.upstreamProxy($0) }
                    write(fd, status: 200, type: "application/vnd.apple.mpegurl", body: Data(rewritten.utf8), head: method == "HEAD", header: request)
                } else {
                    write(fd, status: 200, type: Self.mediaType(upstream, data: data, mime: http.mimeType), body: data, head: method == "HEAD", header: request)
                }
            } else {
                write(fd, status: 404, type: "text/plain", body: Data("unknown".utf8), head: method == "HEAD")
            }
        } catch {
            write(fd, status: 502, type: "text/plain", body: Data((error.localizedDescription).utf8), head: method == "HEAD")
        }
    }

    private func currentPlaylist() async throws -> String {
        lock.lock()
        let cached = warmed
        let final = playlistFinal
        warmed = nil
        let source = playlistSource
        lock.unlock()
        let data: Data
        let base: URL
        if let cached, let final {
            data = cached
            base = final
        } else if let source {
            let loaded = try await loadPlaylist(source, allowUnwrap: false)
            data = loaded.data
            base = loaded.final
        } else {
            throw TunnelError.notPlaylist
        }
        let text = String(decoding: data, as: UTF8.self)
        return HLSRewriter.rewrite(text, base: base) { self.upstreamProxy($0) }
    }

    private func upstreamProxy(_ url: URL) -> String { endpoint("p/\(encode(url))").absoluteString }

    private func waitForFLV(_ url: URL) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 6 * 60 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: pump, delegateQueue: nil)
        pump.onResponse = { [weak self] status in self?.noteStatus(status) }
        pump.onData = { [weak self] data in self?.noteData(data) }
        pump.onComplete = { [weak self] error in self?.noteComplete(error) }
        var request = authorized(url)
        request.timeoutInterval = 6 * 60 * 60
        let task = session.dataTask(with: request)
        lock.lock()
        streamSession = session
        flvTask = task
        lock.unlock()
        task.resume()
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            try Task.checkCancellation()
            let state: (Int, Int?, Bool, Error?) = lock.sync {
                (segmenter.segmentCount, flvStatus, segmenter.rejectedVideo && !segmenter.sawVideo && flvBytes > 256_000, flvError)
            }
            if let status = state.1, !(200..<300).contains(status) { throw TunnelError.unavailable(status) }
            if state.0 >= 1 { return }
            if state.2 { throw TunnelError.unsupported }
            if let error = state.3 { throw error }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if lock.sync({ segmenter.segmentCount }) >= 1 { return }
        throw TunnelError.timeout
    }

    private func noteStatus(_ status: Int) { lock.sync { flvStatus = status } }
    private func noteData(_ data: Data) { lock.sync { flvBytes += data.count; segmenter.append(data) } }
    private func noteComplete(_ error: Error?) {
        lock.sync {
            if stopped { return }
            if segmenter.segmentCount == 0 { flvError = error ?? TunnelError.unavailable(flvStatus ?? 0) }
            segmenter.flush()
        }
    }

    private struct LoadedPlaylist { var data: Data; var source: URL; var final: URL }

    private func loadPlaylist(_ url: URL, allowUnwrap: Bool) async throws -> LoadedPlaylist {
        let (data, http) = try await fetch(url)
        if allowUnwrap, [401, 403, 404, 410, 451, 502].contains(http.statusCode), let nested = PlaybackPlan.embeddedStream(url), nested != url {
            return try await loadPlaylist(nested, allowUnwrap: false)
        }
        guard (200..<300).contains(http.statusCode) else { throw TunnelError.unavailable(http.statusCode) }
        guard Self.isPlaylist(data, mime: http.mimeType) else { throw TunnelError.notPlaylist }
        return LoadedPlaylist(data: data, source: url, final: http.url ?? url)
    }

    private func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await playlistSession.data(for: authorized(url))
        guard let http = response as? HTTPURLResponse else { throw TunnelError.unavailable(0) }
        guard data.count <= 20 * 1024 * 1024 else { throw TunnelError.unavailable(0) }
        return (data, http)
    }

    private func authorized(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        var fields = headers
        if (fields["User-Agent"] ?? "").isEmpty {
            fields["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        }
        for (key, value) in fields where !value.isEmpty {
            let name = key.lowercased()
            if name != "host" && name != "content-length" { request.setValue(value, forHTTPHeaderField: key) }
        }
        return request
    }

    private func readHeaders(_ fd: Int32) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 65536 {
            if data.range(of: Data([13, 10, 13, 10])) != nil { break }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .isoLatin1)
    }

    private func write(_ fd: Int32, status: Int, type: String, body: Data, head: Bool, header: String = "") {
        var payload = body
        var code = status
        var reason = status == 200 ? "OK" : status == 206 ? "Partial Content" : status == 404 ? "Not Found" : "Bad Gateway"
        var extra = "Accept-Ranges: bytes\r\n"
        if let range = Self.byteRange(header, length: body.count), range.lowerBound >= 0, range.lowerBound < body.count {
            let end = min(body.count - 1, range.upperBound - 1)
            payload = body.subdata(in: range.lowerBound...end)
            code = 206
            reason = "Partial Content"
            extra += "Content-Range: bytes \(range.lowerBound)-\(end)/\(body.count)\r\n"
        }
        let headText = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\(extra)\r\n"
        var bytes = Data(headText.utf8)
        if !head { bytes.append(payload) }
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if count <= 0 { break }
                sent += count
            }
        }
    }

    private static func isPlaylist(_ data: Data, mime: String?) -> Bool {
        var body = data.prefix(2048)
        if body.starts(with: [0xEF, 0xBB, 0xBF]) { body = body.dropFirst(3) }
        if body.starts(with: Data("#EXTM3U".utf8)) { return true }
        let type = mime?.lowercased() ?? ""
        return type.contains("mpegurl") || type.contains("m3u8")
    }

    private static func mediaType(_ url: URL, data: Data, mime: String?) -> String {
        if isPlaylist(data, mime: mime) { return "application/vnd.apple.mpegurl" }
        switch url.pathExtension.lowercased() {
        case "ts": return "video/MP2T"
        case "mp4", "m4s", "m4v", "cmfv", "cmfa": return "video/mp4"
        case "aac": return "audio/aac"
        default:
            if let mime, !mime.isEmpty { return mime }
            return "application/octet-stream"
        }
    }

    private static func byteRange(_ header: String, length: Int) -> Range<Int>? {
        guard let line = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("range:") }) else { return nil }
        let value = line.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let span = value.dropFirst(6)
        let parts = span.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first else { return nil }
        if first.isEmpty, let suffix = Int(parts.last ?? "") { return max(0, length - suffix)..<length }
        guard let start = Int(first), start < length else { return nil }
        let endInclusive = (parts.count > 1 && !parts[1].isEmpty ? Int(parts[1]) : nil) ?? (length - 1)
        return start..<min(length, endInclusive + 1)
    }

    private func encode(_ url: URL) -> String {
        Data(url.absoluteString.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func decode(_ token: String) -> URL? {
        var text = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text), let raw = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: raw)
    }
}

private extension NSLock {
    func sync<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}

private final class FLVPump: NSObject, URLSessionDataDelegate {
    var onResponse: ((Int) -> Void)?
    var onData: ((Data) -> Void)?
    var onComplete: ((Error?) -> Void)?
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        onResponse?((response as? HTTPURLResponse)?.statusCode ?? 0)
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { onData?(data) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { onComplete?(error) }
}
