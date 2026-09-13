import XCTest

final class VoiceNotesUITests: XCTestCase {
    func testFreshInstallShowsLocalHomeAndUnconfiguredAI() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["내 노트"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["노트가 없습니다"].exists)
        XCTAssertTrue(app.staticTexts["녹음을 시작하여 첫 노트를 만들어보세요"].exists)
        XCTAssertTrue(app.buttons["liveRecordButton"].exists)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        // Run on a clean simulator. This does not claim microphone or Whisper validation.
        XCTAssertTrue(app.staticTexts["Not Configured"].exists)
    }

    func testMintButtonOpensLiveSpeechScreen() throws {
        let app = XCUIApplication()
        app.launch()

        let recordButton = app.buttons["liveRecordButton"]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 5))
        recordButton.tap()

        XCTAssertTrue(app.staticTexts["음성 인식"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["요약"].exists)
        XCTAssertTrue(app.staticTexts["노트"].exists)
        // A system permission sheet may now be present. Microphone input and live
        // partial results remain physical-device checks, not claims of this UI test.
    }
}
