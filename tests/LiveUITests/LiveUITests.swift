import XCTest

final class LiveUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.tabBars.buttons["频道"].tap()
        return app
    }

    func testRecoveredAPIPlatformRoomSessionRenewalAndPlayback() throws {
        let app = launch()
        app.tabBars.buttons["直播"].tap()
        let platform = app.buttons["platform_38"]
        // NavigationLink may be exposed as a button by SwiftUI accessibility.
        XCTAssertTrue(platform.waitForExistence(timeout: 20))
        platform.tap()
        let room = app.buttons["room_38_fixture"]
        XCTAssertTrue(room.waitForExistence(timeout: 15))
        room.tap()
        let reconnect = app.buttons["重新连接"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 25))
        reconnect.tap()
        let player = app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 20))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已就绪"), object: player)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        app.buttons["收藏视频"].tap()
        app.buttons["关闭播放"].tap()
        app.tabBars.buttons["收藏"].tap()
        XCTAssertTrue(app.staticTexts["测试直播间"].waitForExistence(timeout: 5))
        app.staticTexts["测试直播间"].tap()
        XCTAssertTrue(player.waitForExistence(timeout: 20))
        let reopened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已就绪"), object: player)
        XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: 20), .completed)
    }

    func testHomeAndNavigation() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["openLink"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Stripchat"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Home"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.tabBars.buttons["收藏"].tap()
        XCTAssertTrue(app.staticTexts["还没有收藏"].waitForExistence(timeout: 3))
        app.tabBars.buttons["我的"].tap()
        app.buttons["aboutLink"].tap()
        XCTAssertTrue(app.staticTexts["直播 · 1.0"].waitForExistence(timeout: 3))
    }

    func testInvalidURLStaysInForm() throws {
        let app = launch()
        app.buttons["openLink"].tap()
        let field = app.descendants(matching: .any).matching(identifier: "linkURL").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("javascript:alert(1)")
        app.buttons["confirmOpen"].tap()
        XCTAssertTrue(app.staticTexts["linkError"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["打开链接"].exists)
    }

    func testPasteImportAndPersistInSession() throws {
        let app = launch()
        app.buttons["importChannels"].tap()
        app.segmentedControls.buttons["粘贴内容"].tap()
        let editor = app.textViews["playlistContent"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText("#EXTM3U\n#EXTINF:-1,Test Channel\nhttps://example.com/test.m3u8\n")
        app.buttons["readChannels"].tap()
        let save = app.buttons["saveChannels"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(app.alerts["导入完成"].waitForExistence(timeout: 3))
        app.alerts.buttons["完成"].tap()
        scrollToChannel("Test Channel", in: app)
    }

    private func openFixture(_ app: XCUIApplication, path: String, name: String) {
        app.buttons["openLink"].tap()
        let field = app.descendants(matching: .any).matching(identifier: "linkURL").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("http://127.0.0.1:8765/" + path)
        let nameField = app.textFields["linkName"]
        nameField.tap()
        nameField.typeText(name)
        app.buttons["confirmOpen"].tap()
    }

    private func scrollToChannel(_ name: String, in app: XCUIApplication) {
        let scroll = app.scrollViews["homeScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let interactive = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: scroll)
        XCTAssertEqual(XCTWaiter.wait(for: [interactive], timeout: 5), .completed)
        for _ in 0..<6 {
            if app.staticTexts[name].exists && app.staticTexts[name].isHittable { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 3))
    }

    func testLocalWebsiteLoadingAndCurrentPageFavorite() throws {
        let app = launch()
        openFixture(app, path: "page.html", name: "Web fixture")
        XCTAssertTrue(app.webViews.staticTexts["Local test page"].waitForExistence(timeout: 15))
        app.buttons["收藏当前页面"].tap()
        app.buttons["关闭网页"].tap()
        app.tabBars.buttons["收藏"].tap()
        XCTAssertTrue(app.staticTexts["Web fixture"].waitForExistence(timeout: 3))
    }

    func testNativeVideoBecomesReadyAndEntersHistory() throws {
        let app = launch()
        openFixture(app, path: "sample.mp4", name: "Video fixture")
        let player = app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已就绪"), object: player)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        app.buttons["关闭播放"].tap()
        XCTAssertTrue(app.staticTexts["Video fixture"].waitForExistence(timeout: 3))
    }

    func testNativeHLSBecomesReady() throws {
        let app = launch()
        openFixture(app, path: "sample.m3u8", name: "HLS fixture")
        let player = app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已就绪"), object: player)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        app.buttons["关闭播放"].tap()
        XCTAssertTrue(app.staticTexts["HLS fixture"].waitForExistence(timeout: 3))
    }

    func testRemoteSubscriptionImport() throws {
        let app = launch()
        app.buttons["importChannels"].tap()
        let field = app.descendants(matching: .any).matching(identifier: "subscriptionURL").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("http://127.0.0.1:8765/channels.m3u")
        app.buttons["readChannels"].tap()
        let save = app.buttons["saveChannels"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        save.tap()
        XCTAssertTrue(app.alerts["导入完成"].waitForExistence(timeout: 3))
        app.alerts.buttons["完成"].tap()
        scrollToChannel("Local HLS", in: app)
    }
}
