import XCTest

final class ScanRangeUITests: XCTestCase {
    func testBothScanEntrypointsOpenDateSelectionWithoutStarting() throws {
        let app = XCUIApplication()
        app.launch()
        let scanButtons = app.buttons.matching(identifier: "扫描截图相册")
        XCTAssertTrue(scanButtons.firstMatch.waitForExistence(timeout: 10))
        let count = scanButtons.count
        scanButtons.firstMatch.tap()
        try verifyDateSheet(app)
        app.buttons["scan.range.cancel"].tap()
        XCTAssertFalse(app.navigationBars["选择扫描时间"].exists)
        if count > 1 {
            scanButtons.element(boundBy: count - 1).tap()
            try verifyDateSheet(app)
            app.buttons["scan.range.cancel"].tap()
        }
        XCTAssertFalse(app.buttons["scan.stop"].exists)
    }

    private func verifyDateSheet(_ app: XCUIApplication) throws {
        XCTAssertTrue(app.navigationBars["选择扫描时间"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["scan.range.start"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["scan.range.end"].exists)
        XCTAssertTrue(app.buttons["scan.range.begin"].exists)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 2) {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "需用户选择照片权限"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            throw XCTSkip("系统照片权限需要用户在手机上选择，测试不自动授予权限。")
        }
        XCTAssertFalse(app.buttons["scan.stop"].exists)
        app.buttons["scan.range.last30"].tap()
        app.buttons["scan.range.last7"].tap()
        let ready = NSPredicate(format: "exists == true")
        let count = app.descendants(matching: .any)["scan.range.count"].firstMatch
        let finished = XCTNSPredicateExpectation(predicate: ready, object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 10), .completed)
        if app.staticTexts["0 张"].exists { XCTAssertFalse(app.buttons["scan.range.begin"].isEnabled) }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "扫描时间选择"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
