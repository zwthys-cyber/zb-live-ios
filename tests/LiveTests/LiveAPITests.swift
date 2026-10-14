import XCTest
@testable import Live

final class LiveAPITests: XCTestCase {
    private let vector1 = "Yc95Q9idlyojLmX86uIqL5Eh-X-_LCftYK9ZBfdYdaVUS_lhvPyctMmDtbejWVetB-EGQve-bbNmylkeggmT1oZ71IM3oJQkZotilMP62h9Ao6qinjj1o0UV6SkqEAP2wb8iKx7oyIC1fv476W8P56BmlHxIlsFzZVpJM-HE6PW9nnCj84_wkNJu8TWsErGz10H9fNdj9S278puW_5KtlwB0j1-tca-MssV5ZO5DrMY"
    private let vector2 = "EBESExQVFhcYGRobHB0eHxBdc2qNXITk-3yi0D095FMo6c11fjr_i31QvVHodPEYHFlhqdWxOT32RhCj1HFBL7xqqYDmLAW8olCWyPR-dfhTC4Yu0Vk08tlwrwG-MeoAh3gi3ENw91O2JQFCSPDTchDrK7awYMFZHG1v6KWwlscAPpMTua2IHjpnbQh_bgPwqMKyJVjkl1Z0W5gtWrln6tq-UgAO2COa37XI7ItWkgLhet0Vn_pH9vlABpxLsaN0"

    func testRecoveredRequestSignatureMatchesIndependentVector() {
        XCTAssertEqual(LiveAPICrypto.signature(route: "live/rooms", timestamp: "1791954000", nonce: "00112233445566778899aabbccddeeff"), "vx7VhTV4wgeKsJeqSb4ibmv87hJS4rmDwft0XTnVUx4=")
    }
    func testBothEncryptedEnvelopeModesAndDataSignatures() throws {
        for (mode, payload) in [(1, vector1), (2, vector2)] {
            let envelope = try JSONSerialization.data(withJSONObject: ["code": 0, "enc": mode, "payload": payload])
            let decoded = try LiveAPICrypto.decode(envelope, sessionKey: Data(0..<16))
            let data = try XCTUnwrap(decoded["data"] as? [String: Any])
            XCTAssertEqual(data["message"] as? String, "测试 hello")
            XCTAssertEqual(decoded["code"] as? Int, 0)
            let nested = try XCTUnwrap(data["nested"] as? [String: Any])
            XCTAssertEqual(nested["a"] as? String, "https://example.com/a?b=1&c=2")
        }
    }
    func testSessionCipherRequiresCorrectKeyAndCompleteIV() throws {
        let envelope = try JSONSerialization.data(withJSONObject: ["code": 0, "enc": 2, "payload": vector2])
        XCTAssertThrowsError(try LiveAPICrypto.decode(envelope, sessionKey: Data(repeating: 0, count: 16)))
        XCTAssertThrowsError(try LiveAPICrypto.decrypt(Data(repeating: 0, count: 16), key: LiveAPICrypto.key, iv: Data()))
    }
    func testOrderedJSONFieldKeepsNestedAndEscapedStrings() {
        let text = #"{ "msg": "data", "data" : { "z" : [1, {"text": "a b, } \"data\""}], "a": "测试" }, "sign": "s" }"#
        let expected = #"{"z":[1,{"text":"a b, } \"data\""}],"a":"测试"}"#
        XCTAssertEqual(LiveAPICrypto.rawField("data", in: Data(text.utf8)), Data(expected.utf8))
        XCTAssertNil(LiveAPICrypto.rawField("missing", in: Data(text.utf8)))
        XCTAssertNil(LiveAPICrypto.rawField("data", in: Data("not JSON".utf8)))
    }
    func testRSAEnvelopeHas2048BitCiphertext() throws {
        let wrapped = try LiveAPICrypto.wrap(Data(0..<16), publicKeyDER: LiveAPIConfiguration.fixture.publicKeyDER)
        XCTAssertEqual(Data(base64Encoded: wrapped)?.count, 256)
        XCTAssertThrowsError(try LiveAPICrypto.wrap(Data(0..<16), publicKeyDER: Data()))
    }
    func testSavedRoomIdentitySurvivesStreamURLRefreshAndOldItemsDecode() throws {
        let old = Data(#"{"name":"old","url":"https://example.com/old.m3u8","kind":"media","group":"test"}"#.utf8)
        let legacy = try JSONDecoder().decode(LiveItem.self, from: old)
        XCTAssertNil(legacy.roomID)
        XCTAssertNil(legacy.headers)
        let first = LiveItem(name: "room", url: URL(string: "https://example.com/first.m3u8")!, roomID: "38_42")
        let fresh = LiveItem(name: "room", url: URL(string: "https://example.com/fresh.m3u8")!, roomID: "38_42")
        XCTAssertEqual(first.id, fresh.id)
        XCTAssertNotEqual(first.id, legacy.id)
    }
}
