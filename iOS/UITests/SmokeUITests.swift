import XCTest

/// Walks the app on the fixtures (the fictional household's Monday, offline).
final class SmokeUITests: XCTestCase {
    @MainActor
    func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixtures"]
        app.launch()
        return app
    }

    @MainActor
    func testTodayShowsTheMorning() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Good morning, Sam."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Coffee chat, agency lead"].exists)
        XCTAssertTrue(app.staticTexts["RSVP: Leaders huddle"].exists)
    }

    @MainActor
    func testEveryTabOpens() {
        let app = launch()
        for tab in ["Inbox", "Plans", "People", "Ask", "Today"] {
            app.tabBars.buttons[tab].tap()
        }
        XCTAssertTrue(app.staticTexts["Good morning, Sam."].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAnRSVPCanBeTakenBack() {
        let app = launch()
        app.tabBars.buttons["Plans"].tap()
        let maybe = app.buttons["Maybe"].firstMatch
        XCTAssertTrue(maybe.waitForExistence(timeout: 10))
        maybe.tap()
        let sending = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Sending Maybe'")).firstMatch
        XCTAssertTrue(sending.waitForExistence(timeout: 3))
        app.buttons["Undo"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Your reply emails organizer."].firstMatch.waitForExistence(timeout: 3))
    }

    @MainActor
    func testAQuickNoteGoesOnFamilyAndComesBackOff() {
        let app = launch()
        app.buttons["Add to Hearth: a photo or a note"].tap()
        let note = app.textFields["Quick note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("dentist for robin thurs 3pm")
        app.buttons["Have Claude read it"].tap()
        XCTAssertTrue(app.staticTexts["Robin: dentist"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["One hour is a guess"].exists)
        app.buttons["Add to Family"].tap()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 5))
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.buttons["Add to Family"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSourcesShowsTheRelayAndRules() {
        let app = launch()
        app.buttons["Sources and rules"].tap()
        XCTAssertTrue(app.staticTexts["gmailkit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Surprise guard"].exists)
    }
}
