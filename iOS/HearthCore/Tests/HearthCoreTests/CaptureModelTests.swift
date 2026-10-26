import CoreGraphics
import Foundation
import HearthKit
import HearthKitTestSupport
import ImageIO
import Testing

@testable import HearthCore

@Suite("Capture")
@MainActor
struct CaptureModelTests {
    func app(clock: ManualClock = ManualClock(Fixtures.now)) async -> (AppModel, FixtureCalendar) {
        let calendar = FixtureCalendar()
        var services = AppServices.fixtures(waits: false)
        services.calendar = calendar
        services.clock = clock
        let app = AppModel(services: services)
        await app.refreshAll()
        return (app, calendar)
    }

    @Test func aQuickNoteBecomesAnEventOnFamily() async throws {
        let (app, calendar) = await app()
        let capture = app.capture
        capture.noteText = "dentist for robin thurs 3pm"
        await capture.readNote()
        #expect(capture.phase == .review)
        #expect(capture.toAdd.map(\.title) == ["Robin: dentist"])
        #expect(capture.toAdd.first?.guesses == ["One hour is a guess"])
        #expect(capture.addLabel == "Add to Family")
        #expect(capture.remindLabel == "Remind us Wednesday at 7 PM")

        await capture.add()
        #expect(capture.canUndo)
        #expect(capture.addLabel == "Added to Family")
        let event = try #require(calendar.events.first)
        #expect(event.title == "Robin: dentist")
        #expect(event.start == Fixtures.at("2026-10-29T15:00"))
        #expect(event.end == Fixtures.at("2026-10-29T16:00"))
        #expect(event.alarm == Fixtures.at("2026-10-28T19:00"))
        #expect(event.notes == "From Hearth: “dentist for robin thurs 3pm”")
        #expect(capture.noteText.isEmpty)
        #expect(capture.recent.first?.status == .added)
        #expect(capture.recentTitle(try #require(capture.recent.first)) == "“dentist for robin thurs 3pm”")
    }

    @Test func undoWithinTenSecondsTakesItBack() async throws {
        let clock = ManualClock(Fixtures.now)
        let (app, calendar) = await app(clock: clock)
        app.capture.noteText = "dentist for robin thurs 3pm"
        await app.capture.readNote()
        await app.capture.add()
        #expect(calendar.events.count == 1)
        clock.advance(8)
        await app.capture.undo()
        #expect(calendar.events.isEmpty)
        #expect(app.capture.phase == .review)
        #expect(app.capture.recent.first?.status == .undone)
    }

    @Test func undoAfterTheWindowDoesNothing() async {
        let clock = ManualClock(Fixtures.now)
        let (app, calendar) = await app(clock: clock)
        app.capture.noteText = "dentist for robin thurs 3pm"
        await app.capture.readNote()
        await app.capture.add()
        clock.advance(11)
        #expect(!app.capture.canUndo)
        await app.capture.undo()
        #expect(calendar.events.count == 1)
    }

    @Test func aFlyerPhotoIsReadWithItsDetails() async throws {
        let (app, calendar) = await app()
        await app.capture.read(photo: try Self.tinyJPEG(), source: .flyer)
        #expect(app.capture.phase == .review)
        let fair = try #require(app.capture.toAdd.first)
        #expect(fair.title == "Fall craft fair")
        #expect(fair.cost == "Free")
        app.capture.setRemind(false)
        await app.capture.add()
        let event = try #require(calendar.events.first)
        #expect(event.alarm == nil)
        #expect(event.location == "Community center, main gym")
        #expect(event.notes?.contains("Cost: Free") == true)
        #expect(app.capture.recentTitle(try #require(app.capture.recent.first)) == "Fall craft fair flyer")
        #expect(app.capture.recent.first?.thumbnail != nil)
    }

    @Test func aPaperCalendarWaitsForAnswers() async throws {
        let (app, calendar) = await app()
        let capture = app.capture
        let url = try #require(Bundle.module.url(forResource: "capture-paper-calendar", withExtension: "json"))
        let reading = try HearthJSON.decode(CaptureReading.self, from: Data(contentsOf: url))
        await capture.load(reading, source: .paperCalendar)
        #expect(capture.openQuestions == 2)
        #expect(capture.toAdd.map(\.title) == ["Greeter", "Trash night", "Lunch with Ben"])
        #expect(capture.addLabel == "Add 3 to Family")

        capture.answer("e6", with: "robin")
        capture.answer("e7", with: "skip")
        #expect(capture.openQuestions == 0)
        #expect(capture.toAdd.map(\.title) == ["Greeter", "Trash night", "Lunch with Ben", "Robin: Dr Ahn"])

        capture.remove("e1")
        await capture.add()
        #expect(calendar.events.map(\.title) == ["Lunch with Ben", "Robin: Dr Ahn"])
        #expect(calendar.events.last?.tentative == true)
        #expect(calendar.reminders.map(\.title) == ["Trash night"])
        #expect(calendar.reminders.first?.repeats == CaptureEntry.Repeat(frequency: .weekly))
    }

    @Test func withoutAClaudeKeyItSaysWhereToAddOne() async {
        var services = AppServices.fixtures(waits: false)
        services.secrets = MemorySecretStore([.relayURL: "https://relay.example", .relayKey: "hrk_fixture"])
        let app = AppModel(services: services)
        app.capture.noteText = "dentist thurs 3pm"
        await app.capture.readNote()
        #expect(app.capture.phase == .failed("Add your Claude API key in Sources."))
    }

    @Test func sharedItemsAreReadThenCleared() async throws {
        let (app, _) = await app()
        let inbox = try #require(app.services.inbox)
        try inbox.put(SharedItem(kind: .text, createdAt: Fixtures.now, text: "dentist for robin thurs 3pm", from: "Messages"))
        app.capture.refreshShared()
        let item = try #require(app.capture.shared.first)
        await app.capture.read(shared: item)
        #expect(app.capture.phase == .review)
        #expect(app.capture.shared.isEmpty)
        #expect(inbox.items().isEmpty)
    }

    /// A small JPEG drawn on the spot.
    static func tinyJPEG() throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0.54, blue: 0.24, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
