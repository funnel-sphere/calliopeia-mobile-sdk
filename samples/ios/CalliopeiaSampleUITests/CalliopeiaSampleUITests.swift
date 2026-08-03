import XCTest

final class CalliopeiaSampleUITests: XCTestCase {
    func testPrimaryWorkflowIsVisible() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Calliopeia Sample"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["録音開始"].exists)
        XCTAssertTrue(app.buttons["停止・送信"].exists)
        XCTAssertTrue(app.staticTexts["ジョブ"].exists)
        XCTAssertTrue(app.buttons["状態を更新"].exists)
    }
}
