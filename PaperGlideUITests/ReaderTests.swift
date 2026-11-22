import XCTest

final class ReaderTests: XCTestCase {
    func testGesturesAndPersistentTag() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-fixture-papers", "-librarySortOrder", "Filename"]
        app.launch()
        let paper = app.cells.containing(.staticText, identifier: "Paper 2").firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 20))
        paper.tap()
        let remove = app.buttons["Remove red tag"]
        if remove.exists { remove.tap() }
        app.buttons["Add red tag"].tap()
        XCTAssertTrue(remove.exists)

        // Exercise actual touch gestures, including loading a previously unopened neighbor.
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.55))
        func swipe(_ dx: CGFloat, _ dy: CGFloat) {
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: dx, dy: dy)))
        }
        let ready = app.staticTexts["Opening Paper 2.pdf"]
        XCTAssertTrue(ready.waitForNonExistence(timeout: 15))
        swipe(0, -270)
        XCTAssertTrue(app.navigationBars["Paper 2"].exists)
        swipe(-320, 4)
        XCTAssertTrue(app.navigationBars["Paper 3"].waitForExistence(timeout: 5))
        swipe(320, 0)
        XCTAssertTrue(app.navigationBars["Paper 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(remove.exists)
        app.terminate()
        app.launch()
        app.buttons["Show red-tagged papers"].tap()
        XCTAssertTrue(paper.waitForExistence(timeout: 10))
        XCTAssertFalse(app.cells.containing(.staticText, identifier: "Paper 3").firstMatch.exists)
        paper.tap()
        remove.tap()
        app.navigationBars.buttons["Papers"].tap()
        XCTAssertTrue(app.buttons["Show all papers"].waitForExistence(timeout: 5))
        XCTAssertFalse(paper.exists)
        app.buttons["Show all papers"].tap()
        XCTAssertTrue(paper.waitForExistence(timeout: 5))
    }

    func testSortSearchAndMarkPDF() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PAPERGLIDE_TEST_RUN"] = UUID().uuidString
        app.launchArguments = ["-fixture-papers", "-ink-fixtures"]
        app.launch()
        let sort = app.buttons["Sort papers"]
        XCTAssertTrue(sort.waitForExistence(timeout: 10))
        sort.tap()
        app.buttons["Date modified · newest first"].tap()
        let rows = app.tables.cells
        XCTAssertTrue(rows.element(boundBy: 0).staticTexts["Paper 5"].waitForExistence(timeout: 5))
        rows.element(boundBy: 0).tap()
        app.buttons["Next paper"].tap()
        XCTAssertTrue(app.navigationBars["Paper 4"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Papers"].tap()
        sort.tap()
        app.buttons["Date modified · oldest first"].tap()
        XCTAssertTrue(rows.element(boundBy: 0).staticTexts["Paper 1"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("pEr 4")
        XCTAssertTrue(rows.element(boundBy: 0).staticTexts["Paper 4"].waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 1)
        rows.element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons["Mark PDF"].exists)
        XCTAssertFalse(app.buttons["Save"].exists)
        let width = app.buttons["Pen options"]
        XCTAssertTrue(width.waitForExistence(timeout: 5))
        app.pinch(withScale: 2.8, velocity: 2)
        width.tap()
        app.buttons["Medium"].tap()
        XCTAssertEqual(width.value as? String, "Medium")
        width.tap()
        app.buttons["Fine"].tap()
        XCTAssertEqual(width.value as? String, "Fine")
        width.tap()
        app.buttons["Draw with finger"].tap()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.52))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 120, dy: 60)))
        let undo = app.buttons["Undo last stroke"]
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        XCTAssertFalse(undo.isEnabled)
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 150, dy: -60)))
        let eraser = app.buttons["Stroke eraser"]
        eraser.tap()
        XCTAssertEqual(eraser.value as? String, "On")
        start.withOffset(CGVector(dx: 70, dy: -28)).tap()
        let undoErase = app.buttons["Undo erase"]
        XCTAssertTrue(undoErase.waitForExistence(timeout: 5))
        undoErase.tap()
        XCTAssertTrue(undo.isEnabled)
        eraser.tap()
        XCTAssertEqual(eraser.value as? String, "Off")
        let zoomed = XCTAttachment(screenshot: app.screenshot())
        zoomed.name = "Fine ink at reading zoom"
        zoomed.lifetime = .keepAlways
        add(zoomed)
        app.navigationBars.buttons["Papers"].tap()
        XCTAssertTrue(app.tables.firstMatch.waitForExistence(timeout: 10))
        sort.tap()
        app.buttons["Date created · newest first"].tap()
        app.terminate()
        app.launch()
        let reopened = app.cells.containing(.staticText, identifier: "Paper 4").firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        reopened.tap()
        width.tap()
        app.buttons["Draw with finger"].tap()
        eraser.tap()
        start.withOffset(CGVector(dx: 70, dy: -28)).tap()
        XCTAssertTrue(undoErase.waitForExistence(timeout: 5), "The reopened PDF must contain erasable, saved ink.")
    }
}
