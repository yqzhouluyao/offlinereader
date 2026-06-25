import XCTest

final class OfflineReaderUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesToEmptyLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing")
        app.launch()

        XCTAssertTrue(app.staticTexts["library.empty.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library.empty.import"].exists)
        XCTAssertFalse(app.staticTexts["电子书书架"].exists)
        XCTAssertFalse(app.staticTexts["课程"].exists)
    }

    @MainActor
    func testLibraryGridEditingAndGroups() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing")
        app.launchArguments.append("-ui-testing-seed-library")
        app.launch()

        let bookButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book."))
        XCTAssertTrue(bookButtons.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["电子书书架"].exists)
        XCTAssertFalse(app.staticTexts["课程"].exists)
        XCTAssertGreaterThanOrEqual(bookButtons.count, 6)

        let firstFrame = bookButtons.element(boundBy: 0).frame
        let secondFrame = bookButtons.element(boundBy: 1).frame
        let thirdFrame = bookButtons.element(boundBy: 2).frame
        XCTAssertLessThan(abs(firstFrame.minY - secondFrame.minY), 8)
        XCTAssertLessThan(abs(secondFrame.minY - thirdFrame.minY), 8)
        XCTAssertLessThan(firstFrame.minX, secondFrame.minX)
        XCTAssertLessThan(secondFrame.minX, thirdFrame.minX)

        app.buttons["library.shelf.organize"].tap()
        XCTAssertTrue(app.staticTexts["选择内容"].waitForExistence(timeout: 3))

        let editableBooks = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.edit.book."))
        XCTAssertTrue(editableBooks.element(boundBy: 0).waitForExistence(timeout: 3))
        editableBooks.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["共选择了1个内容"].waitForExistence(timeout: 3))

        app.buttons["library.edit.moveToGroup"].tap()
        XCTAssertTrue(app.staticTexts["移动至分组"].waitForExistence(timeout: 3))

        app.buttons["library.group.createFromMove"].tap()
        let groupNameField = app.textFields["library.group.new.name"]
        XCTAssertTrue(groupNameField.waitForExistence(timeout: 3))
        groupNameField.tap()
        groupNameField.typeText("Biography")
        if app.keyboards.buttons["return"].exists {
            app.keyboards.buttons["return"].tap()
        } else {
            app.keyboards.buttons["Done"].tap()
        }
        if groupNameField.exists {
            app.buttons["library.group.new.confirm"].tap()
        }

        app.buttons["library.edit.cancel"].tap()
        XCTAssertTrue(app.buttons["library.shelf.organize"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Biography"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testLibraryDoesNotShowListenButtons() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing")
        app.launchArguments.append("-ui-testing-seed-library")
        app.launch()

        let bookButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book."))
        XCTAssertTrue(bookButtons.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.listen.book.")).count, 0)
        XCTAssertFalse(app.buttons["listening.miniPlayer.playPause"].exists)
    }
}
