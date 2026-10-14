import XCTest

final class LiveUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
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
        if !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.tap()
        XCTAssertTrue(app.alerts["导入完成"].waitForExistence(timeout: 3))
        app.alerts.buttons["完成"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Test Channel"].waitForExistence(timeout: 3))
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
}
