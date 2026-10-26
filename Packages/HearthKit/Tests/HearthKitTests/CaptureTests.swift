import Foundation
import HearthKitTestSupport
import Testing

@testable import HearthKit

@Suite("Capture")
struct CaptureTests {
    func recorded(_ name: String) throws -> CaptureReading {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Recorded"))
        return try HearthJSON.decode(CaptureReading.self, from: Data(contentsOf: url))
    }

    @Test func theSchemaClosesEveryObjectAndRequiresEveryField() {
        func check(_ schema: JSONValue, path: String) {
            if schema["type"]?.stringValue == "object" {
                #expect(schema["additionalProperties"] == .bool(false), "\(path) must close")
                let properties = schema["properties"]?.objectValue?.keys ?? []
                let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
                #expect(properties == required, "\(path) must require every property")
                for name in properties { check(schema["properties"]?[name] ?? .null, path: path + "." + name) }
            }
            if let items = schema["items"] { check(items, path: path + "[]") }
            for option in schema["anyOf"]?.arrayValue ?? [] { check(option, path: path + "|") }
        }
        check(CapturePrompt.schema, path: "reading")
        // A recorded reply decodes against the same shape.
        #expect(CapturePrompt.schema["properties"]?["entries"]?["items"]?["properties"]?["kind"]?["enum"]?.arrayValue?.count == 4)
    }

    @Test func theRequestCarriesTheImageAndToday() throws {
        let image = CapturePrompt.Image(data: Data([0xFF, 0xD8]), mediaType: "image/jpeg")
        let request = CapturePrompt.request(source: .flyer, text: nil, image: image, now: Fixtures.now, household: Fixtures.household)
        #expect(request.model == .opus)
        #expect(request.effort == .medium)
        #expect(request.outputSchema == CapturePrompt.schema)
        let content = try #require(request.messages.first?.content)
        #expect(content.map(\.type) == ["image", "text"])
        let text = try #require(content.last?.text)
        #expect(text.contains("Today is Monday, October 26, 2026-10-26, 10:08 AM, time zone America/New_York."))
        #expect(text.contains("a photo of a flyer or poster"))
        let system = try #require(request.system)
        #expect(system.contains("the owner is Sam; their partner is Robin"))
        #expect(system.contains("\"Robin: dentist\""))
        #expect(!system.contains("2026"))  // the date stays out of the cached prompt
    }

    @Test func aNoteGoesInAsText() throws {
        let message = CapturePrompt.message(
            source: .note, text: "dentist for robin thurs 3pm", image: nil, now: Fixtures.now,
            household: Fixtures.household)
        #expect(message.content.map(\.type) == ["text"])
        #expect(message.text.contains("The note:\ndentist for robin thurs 3pm"))
    }

    @Test func aPaperCalendarSortsIntoThreeLists() throws {
        let reading = try recorded("capture-paper-calendar")
        let triage = CaptureMatcher.triage(reading.entries, agenda: Agenda(events: Fixtures.week, household: Fixtures.household))
        #expect(triage.needsLook.map(\.id) == ["e6", "e7"])
        #expect(triage.new.map(\.title) == ["Greeter", "Trash night", "Lunch with Ben"])
        #expect(
            triage.alreadyOn.map { "\($0.entry.title) · \($0.event.source.label)" } == [
                "Jordan's birthday · Birthdays", "Trunk or treat · Family",
            ])
    }

    @Test func answersChangeTheEntry() throws {
        let reading = try recorded("capture-paper-calendar")
        let ahn = try #require(reading.entries.first { $0.id == "e6" })
        let theirs = try #require(ahn.question?.options.first { $0.id == "robin" })
        let answered = try #require(ahn.answering(theirs))
        #expect(answered.title == "Robin: Dr Ahn")
        #expect(answered.person == "Robin")
        #expect(answered.question == nil)
        let mineOption = try #require(ahn.question?.options.first { $0.id == "mine" })
        let mine = try #require(ahn.answering(mineOption))
        #expect(mine.person == nil)
        let skipOption = try #require(ahn.question?.options.first { $0.id == "skip" })
        #expect(ahn.answering(skipOption) == nil)

        let night = try #require(reading.entries.first { $0.id == "e7" })
        let eveningOption = try #require(night.question?.options.first { $0.id == "eve" })
        let evening = try #require(night.answering(eveningOption))
        let interval = try #require(evening.interval(in: Fixtures.zone))
        #expect(interval.start == Fixtures.at("2026-11-13T19:00"))
        #expect(interval.end == Fixtures.at("2026-11-13T22:00"))
    }

    @Test func intervalsFollowTheRules() throws {
        let zone = Fixtures.zone
        let allDay = CaptureEntry(id: "a", title: "Fair", date: "2026-11-07")
        #expect(allDay.interval(in: zone) == DateInterval(start: Fixtures.at("2026-11-07T00:00"), end: Fixtures.at("2026-11-08T00:00")))
        let noEnd = CaptureEntry(id: "b", title: "Dentist", date: "2026-10-29", startTime: "15:00")
        #expect(noEnd.interval(in: zone)?.duration == 3600)
        let reminder = CaptureEntry(id: "c", kind: .reminder, title: "Call plumber", date: "2026-10-27", startTime: "08:00")
        #expect(reminder.interval(in: zone)?.duration == 0)
        let lateShow = CaptureEntry(id: "d", title: "Late show", date: "2026-10-30", startTime: "22:00", endTime: "01:00")
        #expect(lateShow.interval(in: zone)?.end == Fixtures.at("2026-10-31T01:00"))
        #expect(CaptureEntry(id: "e", title: "?", date: "soon").interval(in: zone) == nil)
    }

    @Test func titlesMatchLoosely() {
        #expect(CaptureMatcher.words("Mom’s bday!") == ["mom", "birthday"])
        #expect(CaptureMatcher.words("The Harvest Dinner at MCC") == ["harvest", "dinner", "mcc"])
        let fair = CaptureEntry(id: "f", title: "Craft fair", date: "2026-11-07", startTime: "10:00")
        let event = Fixtures.apple("fair", "Fall Craft Fair", "2026-11-07T10:00", "2026-11-07T15:00")
        #expect(CaptureMatcher.matches(fair, event, zone: Fixtures.zone))
        let otherDay = Fixtures.apple("fair2", "Fall Craft Fair", "2026-11-08T10:00", "2026-11-08T15:00")
        #expect(!CaptureMatcher.matches(fair, otherDay, zone: Fixtures.zone))
    }
}
