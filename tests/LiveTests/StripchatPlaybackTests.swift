import XCTest
@testable import Live

final class StripchatPlaybackTests: XCTestCase {
    private let keys = ["fixture-key": "fixture-public-decode-key"]
    private let base = URL(string: "https://media.example/room/source.m3u8")!

    func testSCUsesOriginalMasterAndKeepsAllOtherPlatformsOnTheirOwnPlan() throws {
        let data: [String: Any] = ["platform_code": "sc_chinese", "chat_room_id": 90001,
                                   "cdn_hls_url": "https://relay.example/api.php?r=live/hls&u=low"]
        let streams = try XCTUnwrap(StripchatPlayback.streams(from: data))
        XCTAssertEqual(streams.count, 2)
        XCTAssertTrue(streams.allSatisfy { $0.kind == .stripchat })
        XCTAssertEqual(streams[0].url.absoluteString, "https://edge-hls.doppiocdn.com/hls/90001/master/90001_auto.m3u8")
        XCTAssertEqual(streams[1].url.host, "edge-hls.doppiocdn.net")
        XCTAssertNil(StripchatPlayback.streams(from: ["platform_code": "fixture", "chat_room_id": 90001]))
        XCTAssertEqual(StripchatPlayback.streams(from: ["platform_code": "sc_chinese", "chat_room_id": "../bad"]), [])
    }

    func testPastedSCLinksAreRecognizedWithoutLosingBackupCDN() throws {
        let direct = URL(string: "https://media-hls.doppiocdn.com/b-hls-21/90001/90001.m3u8?psch=v2")!
        XCTAssertEqual(StripchatPlayback.originalMaster(for: direct)?.path, "/hls/90001/master/90001_auto.m3u8")
        let backup = URL(string: "https://edge-hls.doppiocdn.net/hls/90001/master/90001_auto.m3u8")!
        XCTAssertEqual(StripchatPlayback.originalMaster(for: backup)?.host, backup.host)
        XCTAssertNil(StripchatPlayback.originalMaster(for: URL(string: "https://edge-hls.doppiocdn.com.attacker.example/hls/90001/master/90001_auto.m3u8")!))
        XCTAssertEqual(StreamKind.classify(direct), .stripchat)
    }

    func testHighestVariantUsesRealPortraitAndSourceResolutionInsteadOfFilename() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=360x480,NAME="1080p"
        low_1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=720x960,NAME="source"
        original.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,CODECS="mp4a.40.2"
        audio.m3u8
        """
        let variant = try XCTUnwrap(HLSRewriter.highestVariant(in: playlist, base: base))
        XCTAssertEqual(variant.url.lastPathComponent, "original.m3u8")
        XCTAssertEqual(HLSRewriter.pixels(variant.info), 720 * 960)
        let higher = playlist + "\n#EXT-X-STREAM-INF:BANDWIDTH=12000000,RESOLUTION=3840x2160\n4k.m3u8\n"
        XCTAssertEqual(HLSRewriter.highestVariant(in: higher, base: base)?.url.lastPathComponent, "4k.m3u8")
    }

    func testNegotiationSkipsUnknownRetiredDescriptorAndPreservesQuery() throws {
        let playlist = "#EXTM3U\n#EXT-X-MOUFLON:PSCH:v2:retired\n#EXT-X-MOUFLON:PSCH:v2:fixture-key\n"
        let scheme = try XCTUnwrap(MouflonPlaylist.negotiate(playlist, keys: keys))
        XCTAssertEqual(scheme.keyID, "fixture-key")
        let url = try MouflonPlaylist.applying(scheme, to: URL(string: "https://media.example/source.m3u8?token=ab&psch=v1&pkey=old")!)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.filter { $0.name == "pkey" }.map(\.value), ["fixture-key"])
        XCTAssertEqual(query.first { $0.name == "psch" }?.value, "v2")
        XCTAssertEqual(query.first { $0.name == "token" }?.value, "ab")
        XCTAssertThrowsError(try MouflonPlaylist.negotiate("#EXTM3U\n#EXT-X-MOUFLON:PSCH:v2:retired", keys: keys)) {
            XCTAssertEqual($0 as? StripchatPlaybackError, .unknownScheme)
        }
    }

    func testV2IndependentVectorRestoresFullSegmentAndKeepsInitializationAndTiming() throws {
        let playlist = v2Playlist()
        let decoded = try MouflonPlaylist.decode(playlist, base: base, keys: keys)
        XCTAssertTrue(decoded.contains("https://media.example/room/90001_0_fixtureSegment_12345.ts"))
        XCTAssertTrue(decoded.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        XCTAssertTrue(decoded.contains("#EXT-X-MEDIA-SEQUENCE:12"))
        XCTAssertTrue(decoded.contains("#EXTINF:2.0,"))
        XCTAssertFalse(decoded.contains("MOUFLON"))
        XCTAssertFalse(decoded.contains("/media.mp4"))
        let rewritten = HLSRewriter.rewrite(decoded, base: base) { "local:" + $0.path }
        XCTAssertTrue(rewritten.contains("local:/room/90001_0_fixtureSegment_12345.ts"))
        XCTAssertTrue(rewritten.contains("URI=\"local:/room/init.mp4\""))
    }

    func testV1IndependentVectorRestoresFilename() throws {
        // Generated independently with Python hashlib/base64, not the Swift decoder.
        let playlist = """
        #EXTM3U
        #EXT-X-MOUFLON:PSCH:v1:fixture-key
        #EXTINF:2.0,
        #EXT-X-MOUFLON:FILE:t+zA1aKrDg6+DuU1
        media.mp4
        """
        let decoded = try MouflonPlaylist.decode(playlist, base: base, keys: keys)
        XCTAssertTrue(decoded.contains("https://media.example/room/segment00.ts"))
        XCTAssertFalse(decoded.contains("media.mp4"))
    }

    func testAdvertisementIsRejectedEvenThoughItIsAnOtherwiseValidHTTP200Playlist() {
        let playlist = "#EXTM3U\n#EXT-X-MOUFLON-ADVERT\n#EXTINF:2.0,\nad.mp4\n#EXT-X-ENDLIST\n"
        XCTAssertThrowsError(try MouflonPlaylist.decode(playlist, base: base, keys: keys)) {
            XCTAssertEqual($0 as? StripchatPlaybackError, .unavailable)
        }
    }

    func testMalformedOrUnpairedSegmentAndCrossHostURIStopPlayback() {
        let invalid = [
            v2Playlist().replacingOccurrences(of: "cnsjw/Rr32H3KLzfDuo", with: "%%%"),
            v2Playlist().replacingOccurrences(of: "https://media.example/room/media.mp4", with: "https://media.example/room/other.ts"),
            v2Playlist().replacingOccurrences(of: "https://media.example/room/90001", with: "https://other.example/room/90001"),
            "#EXTM3U\n#EXTINF:2.0,\nmedia.mp4\n"
        ]
        for playlist in invalid {
            XCTAssertThrowsError(try MouflonPlaylist.decode(playlist, base: base, keys: keys)) {
                XCTAssertEqual($0 as? StripchatPlaybackError, .invalidSegment)
            }
        }
    }

    func testTunnelRefreshesMasterWhenDescriptorStartsReturningAnAdvertisement() async throws {
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8765/sc/rotation/reset")!)
        let tunnel = PlaybackTunnel(mouflonKeys: MouflonPlaylist.fixtureKeys)
        defer { tunnel.stop() }
        let master = URL(string: "http://127.0.0.1:8765/sc/hls/90002/master/90002_auto.m3u8")!
        let local = try await tunnel.open([StreamCandidate(url: master, kind: .stripchat)], headers: ["Origin": "https://stripchat.com"])
        // The first read consumes the warmed playlist. The second must detect
        // the retired key's HTTP-200 advert and obtain the new master descriptor.
        for _ in 0..<2 {
            let (data, response) = try await URLSession.shared.data(from: local)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(text.contains("#EXTINF:"))
            XCTAssertFalse(text.contains("MOUFLON"))
            XCTAssertFalse(text.contains("media.mp4"))
        }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8765/sc/rotation/state")!)
        let state = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(state["retired"] as? Bool, true)
        XCTAssertGreaterThan(state["new_reads"] as? Int ?? 0, 0)
    }

    private func v2Playlist() -> String {
        """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-MOUFLON:PSCH:v2:fixture-key
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:12
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:2.0,
        #EXT-X-MOUFLON:URI:https://media.example/room/90001_0_cnsjw/Rr32H3KLzfDuo_12345.ts
        https://media.example/room/media.mp4
        """
    }
}
