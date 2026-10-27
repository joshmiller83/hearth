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
    func testArchivingAQueueCanBeUndone() {
        let app = launch()
        app.tabBars.buttons["Inbox"].tap()
        app.buttons["Archive, 5"].tap()
        let archive = app.buttons["Archive 5"]
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        archive.tap()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3))
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.buttons["Archive 5"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testAReplyIsDraftedAndSent() {
        let app = launch()
        app.tabBars.buttons["Inbox"].tap()
        let row = app.staticTexts["Next steps: Senior Engineer"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        // Eyebrow labels are upper case on screen and to VoiceOver.
        let draft = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Claude's draft")).firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["What Claude looked at"].waitForExistence(timeout: 5))
        app.buttons["Send now"].tap()
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Sent'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
    }

    @MainActor
    func testAskPlansABirthdayAndUndoTakesItBack() {
        let app = launch()
        app.tabBars.buttons["Ask"].tap()
        let field = app.descendants(matching: .any).matching(identifier: "Ask Hearth").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Mom's birthday is next week. Handle it, but run it by me first.")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.buttons["Do these 3"].waitForExistence(timeout: 10))
        let trace = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'people_get'")).firstMatch
        XCTAssertTrue(trace.exists)
        app.buttons["Do these 3"].tap()
        let done = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Done.'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.buttons["Do these 3"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSignalsQuietTheChatter() {
        let app = launch()
        let bell = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Signals'")).firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 10))
        bell.tap()
        XCTAssertTrue(app.staticTexts["Review requested on #218"].waitForExistence(timeout: 5))
        app.buttons["Remind me at 5"].tap()
        XCTAssertTrue(app.staticTexts["Reminder set for 5:00 PM"].waitForExistence(timeout: 5))
        app.buttons["Mark read: GitHub, subscribed threads"].tap()
        let cleared = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'GitHub, subscribed threads: marked'")).firstMatch
        XCTAssertTrue(cleared.waitForExistence(timeout: 5))
    }

    @MainActor
    func testSourcesShowsTheRelayAndRules() {
        let app = launch()
        app.buttons["Sources and rules"].tap()
        XCTAssertTrue(app.staticTexts["gmailkit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Surprise guard"].exists)
    }
}
