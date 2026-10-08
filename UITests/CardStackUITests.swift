import XCTest

final class CardStackUITests: XCTestCase {
    func testMultiParagraphCollectionDisplaysOnHomeInsteadOfReprocessing() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixtures"]; app.launch()
        let search = app.textFields["搜索截图"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("测试资料\n")
        let image = app.buttons["card.00000000-0000-0000-0000-000000000007.image"]
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["文字摘录存在冲突"].exists)
        app.buttons["信息库"].tap()
        app.buttons["library.reprocessing"].tap()
        XCTAssertTrue(app.buttons["reprocessing.00000000-0000-0000-0000-000000000010.edit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["reprocessing.00000000-0000-0000-0000-000000000007.edit"].exists)
    }

    func testReprocessingIsOnlyInLibraryAndManualCompletionReturnsHome() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixtures"]; app.launch()
        XCTAssertTrue(app.buttons["stack.collectionCodes.toggle"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["缺门店测试截图"].exists)
        XCTAssertFalse(app.buttons["library.reprocessing"].exists)
        app.buttons["信息库"].tap()
        app.buttons["library.reprocessing"].tap()
        let edit = app.buttons["reprocessing.00000000-0000-0000-0000-000000000010.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        let field = app.textFields["餐厅 / 门店"].firstMatch
        let multiline = app.textViews["餐厅 / 门店"].firstMatch
        let target = field.exists ? field : multiline
        XCTAssertTrue(target.waitForExistence(timeout: 5)); target.tap(); target.typeText("肯德基")
        app.buttons["detail.save"].tap()
        XCTAssertTrue(app.staticTexts["修改已保存"].waitForExistence(timeout: 5))
        app.alerts.buttons["好"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["没有需要重新处理的截图"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["今天"].tap()
        app.buttons["stack.collectionCodes.toggle"].tap()
        XCTAssertTrue(app.staticTexts["缺门店测试截图"].waitForExistence(timeout: 5))
    }

    func testRapidToggleAndReducedMotionKeepFinalState() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixtures", "--reduce-motion"]; app.launch()
        let toggle = app.buttons["stack.collectionCodes.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap(); toggle.tap(); toggle.tap()
        XCTAssertTrue(app.buttons["card.00000000-0000-0000-0000-000000000002.image"].waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertFalse(app.buttons["card.00000000-0000-0000-0000-000000000002.image"].exists)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<18 {
            if element.exists && element.isHittable && element.frame.midY > app.frame.height * 0.22 && element.frame.midY < app.frame.height * 0.70 { return }
            let above = element.exists && element.frame.midY < app.frame.height * 0.22
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.4 : 0.70))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.70 : 0.40))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
    }
    func testSearchExpandsMatchingGroupAndPreservesEmptyGroups() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixtures"]; app.launch()
        let search = app.textFields["搜索截图"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("顺丰\n")
        let third = app.buttons["card.00000000-0000-0000-0000-000000000003.image"]
        XCTAssertTrue(third.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["card.00000000-0000-0000-0000-000000000001.image"].exists)
        app.buttons["清除搜索"].tap()
        XCTAssertTrue(app.buttons["card.00000000-0000-0000-0000-000000000001.image"].waitForExistence(timeout: 5))
        app.buttons["已完成"].tap()
        for group in ["collectionCodes", "schedules", "purchases", "collections"] {
            let header = app.buttons["stack.\(group).toggle"]
            for _ in 0..<8 where !header.exists { app.swipeUp() }
            XCTAssertTrue(header.exists)
            XCTAssertFalse(header.isEnabled)
        }
    }
    func testLargeTextHistoricalCardsAndMissingImage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixtures", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["stack.collectionCodes.toggle"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "最大辅助字号卡片"; screenshot.lifetime = .keepAlways; add(screenshot)
        let collection = app.buttons["stack.collections.toggle"]
        reveal(collection, in: app)
        XCTAssertTrue(collection.isHittable); collection.tap()
        XCTAssertTrue(collection.label.contains("收起"), collection.label)
        let missing = app.buttons["card.00000000-0000-0000-0000-000000000009.image"]
        reveal(missing, in: app)
        XCTAssertTrue(app.staticTexts["历史未分类"].firstMatch.exists)
        XCTAssertTrue(missing.isHittable); missing.tap()
        XCTAssertTrue(app.staticTexts["原图暂时无法打开"].waitForExistence(timeout: 5))
        app.buttons["screenshot.close"].tap()
        let details = app.buttons["card.00000000-0000-0000-0000-000000000009.details"]
        reveal(details, in: app)
        details.tap()
        XCTAssertTrue(app.navigationBars["信息详情"].waitForExistence(timeout: 5))
    }
    func testStackExpandImageAndDetailsAreIndependent() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixtures"]
        app.launch()
        let first = "00000000-0000-0000-0000-000000000001"
        let second = "00000000-0000-0000-0000-000000000002"
        XCTAssertTrue(app.buttons["stack.collectionCodes.toggle"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["card.\(second).image"].exists)
        app.buttons["card.\(first).image"].tap()
        XCTAssertTrue(app.buttons["screenshot.close"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["信息详情"].exists)
        let canvas = app.descendants(matching: .any)["screenshot.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        canvas.doubleTap()
        canvas.pinch(withScale: 1.5, velocity: 1)
        canvas.swipeUp()
        app.buttons["screenshot.close"].tap()
        app.buttons["stack.collectionCodes.toggle"].tap()
        XCTAssertTrue(app.buttons["card.\(second).image"].waitForExistence(timeout: 5))
        app.buttons["stack.collectionCodes.toggle"].tap()
        XCTAssertFalse(app.buttons["card.\(second).image"].exists)
        let details = app.buttons.matching(identifier: "card.\(first).details").firstMatch
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: details)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
        details.tap()
        XCTAssertTrue(app.navigationBars["信息详情"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
    }
}
