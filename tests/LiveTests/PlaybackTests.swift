import XCTest
@testable import Live

final class PlaybackTests: XCTestCase {
    func testClientIdentifiesAsCurrentServiceRelease() {
        XCTAssertEqual(PlaybackPlan.clientVersion, "1.1.14")
        XCTAssertEqual(PlaybackPlan.clientBuild, "124")
    }

    func testPlaybackPlanKeepsHLSThenFLVAndDropsProprietaryRelays() throws {
        let data: [String: Any] = [
            "cdn_hls_url": "https://cdn.example/live/a.m3u8?token=1",
            "flv_url": "http://cdn.example/live/flv?app=live&stream=1",
            "rtmp_url": "rtmp://cdn.example/live/1",
            "play_url": "agora://app|channel|1"
        ]
        let streams = PlaybackPlan.streams(from: data)
        XCTAssertEqual(streams.map(\.kind), [.hls, .flv])
        XCTAssertEqual(streams[0].url.path, "/live/a.m3u8")
        XCTAssertEqual(streams[1].url.path, "/live/flv")
    }

    func testEmbeddedRelayAddressIsRecoveredFromForbiddenProxy() throws {
        let proxy = try XCTUnwrap(URL(string: "https://edge.example/bt-edge/api.php?r=live/hls&u=https%3A%2F%2Fstream.example%2F720%2Findex.m3u8%3Ftoken%3Dab"))
        let upstream = try XCTUnwrap(PlaybackPlan.embeddedStream(proxy))
        XCTAssertEqual(upstream.absoluteString, "https://stream.example/720/index.m3u8?token=ab")
        XCTAssertNil(PlaybackPlan.embeddedStream(try XCTUnwrap(URL(string: "https://cdn.example/a.m3u8"))))
    }

    func testMasterPlaylistKeepsSharpestVariantAndItsAudio() {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="low",NAME="Low",DEFAULT=YES,URI="low-audio.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="high",NAME="High",DEFAULT=YES,URI="high-audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=400000,RESOLUTION=426x240,CODECS="avc1.42c01e,mp4a.40.2",AUDIO="low"
        240.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=7000000,RESOLUTION=1920x1080,CODECS="avc1.64002a,mp4a.40.2",AUDIO="high"
        1080.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="high"
        720.m3u8
        """
        let rewritten = HLSRewriter.rewrite(playlist, base: URL(string: "https://cdn.example/live/master.m3u8")!) { "local:" + $0.path }
        XCTAssertTrue(rewritten.contains("1920x1080"))
        XCTAssertTrue(rewritten.contains("local:/live/1080.m3u8"))
        XCTAssertTrue(rewritten.contains("local:/live/high-audio.m3u8"))
        XCTAssertFalse(rewritten.contains("426x240"))
        XCTAssertFalse(rewritten.contains("1280x720"))
        XCTAssertFalse(rewritten.contains("low-audio"))
        XCTAssertTrue(rewritten.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
    }

    func testMediaPlaylistDropsLowLatencyPartialsAndResolvesSegments() {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:2
        #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.000
        #EXTINF:2.000,
        segment.ts
        #EXT-X-PART:DURATION=0.500,URI="part.mp4"
        #EXT-X-PRELOAD-HINT:TYPE=PART,URI="next.mp4"
        #EXT-X-MAP:URI="init.mp4"
        """
        let rewritten = HLSRewriter.rewrite(playlist, base: URL(string: "https://cdn.example/cam/playlist.m3u8")!) { $0.absoluteString }
        XCTAssertTrue(rewritten.contains("https://cdn.example/cam/segment.ts"))
        XCTAssertTrue(rewritten.contains("URI=\"https://cdn.example/cam/init.mp4\""))
        XCTAssertFalse(rewritten.contains("EXT-X-PART:"))
        XCTAssertFalse(rewritten.contains("EXT-X-SERVER-CONTROL"))
        XCTAssertFalse(rewritten.contains("EXT-X-PRELOAD-HINT"))
        XCTAssertTrue(rewritten.contains("#EXTINF:2.000"))
    }

    func testLowRenditionAddressOffersSharperSiblings() {
        let url = URL(string: "https://cdn.example/live/480p/index.m3u8?token=ab")!
        let upgrades = HLSRewriter.upgradeURLs(for: url)
        XCTAssertTrue(upgrades.contains { $0.path == "/live/1080p/index.m3u8" && $0.query == "token=ab" })
        XCTAssertTrue(upgrades.contains { $0.path == "/live/720p/index.m3u8" })
        XCTAssertTrue(upgrades.contains { $0.path == "/live/auto/index.m3u8" })
        XCTAssertFalse(upgrades.contains { $0.path.contains("480") })
        XCTAssertTrue(HLSRewriter.upgradeURLs(for: URL(string: "https://cdn.example/live/master.m3u8")!).isEmpty)
    }

    func testSharpnessPrefersDeclaredFrameOverALowMediaPlaylist() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=400000,RESOLUTION=426x240
        240.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080.m3u8
        """
        XCTAssertGreaterThanOrEqual(HLSRewriter.sharpness(master), HLSRewriter.hdThreshold)
        XCTAssertLessThan(HLSRewriter.sharpness("#EXTM3U\n#EXTINF:2.0,\nseg_480p.ts\n"), HLSRewriter.hdThreshold)
        XCTAssertFalse(HLSRewriter.isDirectlyPlayable("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n"))
        XCTAssertFalse(HLSRewriter.isDirectlyPlayable("#EXTM3U\n#EXT-X-MOUFLON:1\n"))
        XCTAssertTrue(HLSRewriter.isDirectlyPlayable("#EXTM3U\n#EXTINF:2.0,\na.ts\n"))
    }

    func testProgramTableMatchesMPEGCRC() {
        let packet = MPEGTS.pat(continuity: 0)
        let expected: [UInt8] = [0x47, 0x40, 0x00, 0x10, 0x00, 0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xF0, 0x00, 0x2A, 0xB1, 0x04, 0xB2]
        XCTAssertEqual(packet.count, 188)
        XCTAssertEqual(packet[0], 0x47)
        XCTAssertEqual(Array(packet.prefix(expected.count)), expected)
    }

    func testFLVRemuxProducesDecodableTransportStream() throws {
        let segmenter = FLVSegmenter()
        segmenter.append(sampleFLV())
        segmenter.flush()
        let data = try XCTUnwrap(segmenter.segment(at: 0))
        XCTAssertEqual(data.count % 188, 0)
        XCTAssertEqual(data.first, 0x47)
        XCTAssertTrue(data.starts(with: Data(MPEGTS.pat(continuity: 0))))
        XCTAssertTrue(data.range(of: Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x64, 0x00])) != nil)
        XCTAssertTrue(data.range(of: Data([0xFF, 0xF1])) != nil)
        XCTAssertTrue(segmenter.playlist().contains("#EXT-X-MEDIA-SEQUENCE:0"))
        XCTAssertTrue(segmenter.sawVideo)
    }

    private func sampleFLV() -> Data {
        var body = Data([0x46, 0x4C, 0x56, 0x01, 0x05, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00])
        let avc = Data([0x01, 0x64, 0x00, 0x1E, 0xFF, 0xE1, 0x00, 0x03, 0x67, 0x64, 0x00, 0x01, 0x00, 0x03, 0x68, 0xEE, 0x06])
        body.append(tag(type: 9, time: 0, payload: Data([0x17, 0x00, 0x00, 0x00, 0x00]) + avc))
        body.append(tag(type: 8, time: 0, payload: Data([0xAF, 0x00, 0x12, 0x10])))
        body.append(tag(type: 9, time: 0, payload: Data([0x17, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x65, 0x88, 0x84])))
        body.append(tag(type: 8, time: 23, payload: Data([0xAF, 0x01, 0x21, 0x10, 0x04, 0x60])))
        body.append(tag(type: 9, time: 2000, payload: Data([0x17, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x65, 0x88, 0x84])))
        return body
    }

    private func tag(type: UInt8, time: UInt32, payload: Data) -> Data {
        var data = Data([type, UInt8((payload.count >> 16) & 0xFF), UInt8((payload.count >> 8) & 0xFF), UInt8(payload.count & 0xFF)])
        data.append(contentsOf: [UInt8((time >> 16) & 0xFF), UInt8((time >> 8) & 0xFF), UInt8(time & 0xFF), UInt8((time >> 24) & 0xFF), 0, 0, 0])
        data.append(payload)
        let previous = data.count
        data.append(contentsOf: [UInt8((previous >> 24) & 0xFF), UInt8((previous >> 16) & 0xFF), UInt8((previous >> 8) & 0xFF), UInt8(previous & 0xFF)])
        return data
    }
}
