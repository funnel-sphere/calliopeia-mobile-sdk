import XCTest

final class CalliopeiaSampleUITests: XCTestCase {
    func testPrimaryWorkflowIsVisible() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Calliopeia Sample"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["録音開始"].exists)
        XCTAssertFalse(app.buttons["録音を送信"].isEnabled)
        XCTAssertTrue(app.staticTexts["job-status"].exists)
        XCTAssertTrue(app.buttons["録音開始"].isEnabled)
    }
}
