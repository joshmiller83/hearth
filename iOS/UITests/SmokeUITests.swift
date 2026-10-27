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
    func testArchivingAQueueLeavesOutWhatYouUncheckAndCanBeUndone() {
        let app = launch()
        app.tabBars.buttons["Inbox"].tap()
        app.buttons["Archive, 5"].tap()
        XCTAssertTrue(app.buttons["Archive 5"].waitForExistence(timeout: 5))
        // The GitHub bundle: both of its messages stay.
        app.buttons.matching(NSPredicate(format: "label == %@ AND value == %@", "Leave out of Archive", "GitHub")).firstMatch.tap()
        let archive = app.buttons["Archive 3"]
        XCTAssertTrue(archive.waitForExistence(timeout: 3))
        archive.tap()
        // The countdown sits above the button; the button stays.
        let countdown = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Archiving 3 in'")).firstMatch
        XCTAssertTrue(countdown.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Nothing to archive"].exists)
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.buttons["Archive 3"].waitForExistence(timeout: 3))
        app.buttons.matching(NSPredicate(format: "label == %@", "Put back in Archive")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Archive 5"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testATextWaitingOnYouOpensAndCanBeSetAside() {
        let app = launch()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Carol Rivera: Are you all coming Sunday?'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Bring the good serving dish'")).firstMatch
                .waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open in Messages"].exists)
        app.buttons["Not for me"].tap()
        XCTAssertFalse(app.buttons["Not for me"].waitForExistence(timeout: 1))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertFalse(row.waitForExistence(timeout: 2))
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
    func testPeopleIdeasAndThePartnerPlan() {
        let app = launch()
        app.tabBars.buttons["People"].tap()
        let hold = app.buttons["Hold Tue 7:30 PM"]
        XCTAssertTrue(hold.waitForExistence(timeout: 10))
        hold.tap()
        XCTAssertTrue(app.staticTexts["Tuesday call held."].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Anniversary with Robin'")).firstMatch.tap()
        let plan = app.buttons["Plan the Thai dinner"]
        XCTAssertTrue(plan.waitForExistence(timeout: 10))
        plan.tap()
        XCTAssertTrue(app.buttons["Undo the hold"].waitForExistence(timeout: 5))
        app.buttons["Undo the hold"].tap()
        XCTAssertTrue(app.buttons["Plan the Thai dinner"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAroundTownAndANewFeed() {
        let app = launch()
        app.tabBars.buttons["Plans"].tap()
        app.buttons["Around town"].tap()
        let add = app.buttons["Add Author talk at the public library to calendar"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(app.buttons["Remove Author talk at the public library from calendar"].waitForExistence(timeout: 5))

        app.buttons["Event feeds: add one with Claude"].tap()
        let field = app.descendants(matching: .any).matching(identifier: "Message Claude about event feeds").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("The community center has a calendar online somewhere. Can you add it?")
        app.buttons["Send"].tap()
        let keep = app.buttons["Add, keep those 3"]
        XCTAssertTrue(keep.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: keep)], timeout: 5)
        keep.tap()
        let added = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Added the community center feed, 3 of 14 kept'"))
        XCTAssertTrue(added.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Undo"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Add, keep those 3"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSourcesShowsTheRelayAndRules() {
        let app = launch()
        app.buttons["Sources and rules"].tap()
        XCTAssertTrue(app.staticTexts["gmailkit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Surprise guard"].exists)
    }
}
