import XCTest
@testable import Live

final class PlaylistTests: XCTestCase {
    func testValidURLIsNormalizedAndKeepsTokens() throws {
        let url = try LinkValidator.parse("  HTTPS://EXAMPLE.COM/live.m3u8?token=a%2Fb#room  ")
        XCTAssertEqual(url.host, "example.com")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.query, "token=a%2Fb")
        XCTAssertEqual(url.fragment, "room")
    }

    func testRejectsUnsafeOrIncompleteAddresses() {
        for text in ["", "example.com/a", "javascript:alert(1)", "file:///tmp/video", "https://user:password@example.com/a", "https://example.com/a b", "ftp://example.com/a", "https://"] {
            XCTAssertThrowsError(try LinkValidator.parse(text), text)
        }
    }

    func testURLIdentityIgnoresNameAndKeepsDistinctRooms() throws {
        let url = try LinkValidator.parse("https://example.com/room?a=1")
        XCTAssertEqual(LiveItem(name: "A", url: url).id, LiveItem(name: "B", url: url).id)
        XCTAssertNotEqual(LiveItem(name: "A", url: url).id, LiveItem(name: "A", url: try LinkValidator.parse("https://example.com/room?a=2")).id)
    }

    func testDirectMediaDetection() throws {
        XCTAssertEqual(LinkKind.detect(try LinkValidator.parse("https://example.com/a.M3U8?token=1")), .media)
        XCTAssertEqual(LinkKind.detect(try LinkValidator.parse("https://example.com/room/1")), .web)
    }

    func testM3UWithBOMCRLFQuotedCommaAndDuplicates() throws {
        let text = "\u{FEFF}#EXTM3U\r\n#EXTINF:-1 group-title=\"News, live\",Test channel\r\nhttps://example.com/live.m3u8\r\n#EXTINF:-1,Duplicate\r\nhttps://example.com/live.m3u8\r\n#EXTINF:-1,Invalid\r\njavascript:alert(1)\r\n"
        let items = try PlaylistParser.parse(Data(text.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "Test channel")
        XCTAssertEqual(items[0].group, "News, live")
        XCTAssertEqual(items[0].kind, .media)
    }

    func testRelativeSubscriptionLinks() throws {
        let text = "#EXTM3U\n#EXTINF:-1,Relative\n../streams/live.m3u8\n"
        let items = try PlaylistParser.parse(Data(text.utf8), baseURL: URL(string: "https://example.com/list/channels.m3u"))
        XCTAssertEqual(items[0].url.absoluteString, "https://example.com/streams/live.m3u8")
    }

    func testHLSIsNotImportedAsHundredsOfSegments() {
        for marker in ["#EXT-X-TARGETDURATION:6", "#EXT-X-STREAM-INF:BANDWIDTH=800000", "#EXT-X-MEDIA-SEQUENCE:1"] {
            XCTAssertThrowsError(try PlaylistParser.parse(Data("#EXTM3U\n\(marker)\nsegment.ts".utf8))) { error in
                guard let liveError = error as? LiveError, case .hlsPlaylist = liveError else { return XCTFail("Wrong HLS error: \(error)") }
            }
        }
    }

    func testWrappedJSONAndExplicitWebKind() throws {
        let json = "{\"data\":{\"list\":[{\"title\":\"Channel\",\"play_url\":\"https://example.com/live.m3u8\"},{\"name\":\"Site\",\"url\":\"https://example.com/watch\",\"kind\":\"web\"}]}}"
        let items = try PlaylistParser.parse(Data(json.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].kind, .media)
        XCTAssertEqual(items[1].kind, .web)
    }

    func testJSONRejectsUnrecognizedAndInvalidInput() {
        for json in ["{}", "{bad json}", "[{\"name\":\"No URL\"}]", "{\"data\":[{\"url\":\"file:///etc/passwd\"}]}"] {
            XCTAssertThrowsError(try PlaylistParser.parse(Data(json.utf8)))
        }
    }

    func testPlainTextLinksAndEmptyLists() throws {
        let items = try PlaylistParser.parse(Data("https://example.com/a.mp4\nhttps://example.com/room\n".utf8))
        XCTAssertEqual(items.map(\.kind), [.media, .web])
        XCTAssertThrowsError(try PlaylistParser.parse(Data("#EXTM3U\n#comment".utf8)))
        XCTAssertThrowsError(try PlaylistParser.parse(Data()))
    }

    func testOversizeImportIsRejected() {
        XCTAssertThrowsError(try PlaylistParser.parse(Data(repeating: 65, count: PlaylistParser.maximumBytes + 1)))
    }

    func testPlatformEntriesAreValidWebsites() throws {
        XCTAssertEqual(Platforms.all.count, 7)
        for item in Platforms.all {
            XCTAssertEqual(item.kind, .web)
            XCTAssertEqual(item.url, try LinkValidator.parse(item.url.absoluteString))
        }
    }
}
