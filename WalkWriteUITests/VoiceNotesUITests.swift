import XCTest

final class VoiceNotesUITests: XCTestCase {
    func testFreshInstallShowsLocalHomeAndUnconfiguredAI() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Voice Notes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Record a voice note"].exists)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        // Run on a clean simulator. This does not claim microphone or Whisper validation.
        XCTAssertTrue(app.staticTexts["Not Configured"].exists)
    }
}
