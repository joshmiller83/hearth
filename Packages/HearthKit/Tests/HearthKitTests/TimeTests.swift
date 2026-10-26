import Foundation
import Testing

@testable import HearthKit

@Suite("RFC 3339 and formatting")
struct TimeTests {
    let eastern = TimeZone(identifier: "America/New_York")!

    @Test(arguments: [
        ("2026-10-29T19:00-04:00", "2026-10-29T23:00:00Z"),  // gmailkit: minutes only
        ("2026-10-29T19:00:00-04:00", "2026-10-29T23:00:00Z"),
        ("2026-10-29T23:00:00Z", "2026-10-29T23:00:00Z"),
        ("2026-10-29T23:00:00.250Z", "2026-10-29T23:00:00Z"),
        ("2026-10-29T19:00:00-0400", "2026-10-29T23:00:00Z"),
        ("2026-10-29T19:00", "2026-10-29T23:00:00Z"),  // no offset: read in the zone
        ("2026-12-01T19:00", "2026-12-02T00:00:00Z"),  // EST, not EDT
        ("2026-10-29", "2026-10-29T04:00:00Z"),  // all day: local midnight
    ])
    func parsesTheShapesWeSee(text: String, utc: String) throws {
        let parsed = try #require(RFC3339.parse(text, zone: eastern))
        #expect(RFC3339.format(parsed.date) == utc)
    }

    @Test func dateOnlyAndOffsetFlags() throws {
        #expect(try #require(RFC3339.parse("2026-10-29", zone: eastern)).isDateOnly)
        #expect(try #require(RFC3339.parse("2026-10-29T19:00Z", zone: eastern)).hadOffset)
        #expect(try #require(RFC3339.parse("2026-10-29T19:00", zone: eastern)).hadOffset == false)
    }

    @Test(arguments: ["", "2026-13-01", "2026-10-29T25:00", "yesterday", "2026-10-29T19:00+", "2026-10-29T19:00:00Zjunk"])
    func rejectsGarbage(text: String) {
        #expect(RFC3339.parse(text, zone: eastern) == nil)
    }

    @Test func formatsWithAnOffset() {
        let date = RFC3339.date("2026-10-29T23:00:00Z")!
        #expect(RFC3339.format(date, zone: eastern) == "2026-10-29T19:00:00-04:00")
        #expect(RFC3339.day(date, zone: eastern) == "2026-10-29")
    }

    @Test func fmtSpeaksLikeTheDesign() {
        let fmt = Fmt(zone: eastern)
        let start = RFC3339.date("2026-10-29T19:00", zone: eastern)!
        let end = RFC3339.date("2026-10-29T20:30", zone: eastern)!
        #expect(fmt.time(start) == "7:00 PM")
        #expect(fmt.timeRange(start, end) == "7:00–8:30 PM")
        #expect(fmt.shortDay(start) == "Thu, Oct 29")
        #expect(fmt.when(start, end, allDay: false) == "Thu, Oct 29 · 7:00–8:30 PM")
        #expect(fmt.longDay(start) == "Thursday, October 29")
        #expect(fmt.weekdayTag(start) == "THU")

        let late = RFC3339.date("2026-10-26T11:30", zone: eastern)!
        let afternoon = RFC3339.date("2026-10-26T13:00", zone: eastern)!
        #expect(fmt.timeRange(late, afternoon) == "11:30 AM–1:00 PM")
        #expect(fmt.time(RFC3339.date("2026-10-26T00:05", zone: eastern)!) == "12:05 AM")
    }

    @Test func relativeTimes() {
        let fmt = Fmt(zone: eastern)
        let now = RFC3339.date("2026-10-26T10:08", zone: eastern)!
        #expect(fmt.relative(now.addingTimeInterval(52 * 60), now: now) == "in 52 min")
        #expect(fmt.relative(now.addingTimeInterval(-2 * 3600), now: now) == "2 h ago")
        #expect(fmt.relative(now.addingTimeInterval(20), now: now) == "now")
        #expect(fmt.relative(now.addingTimeInterval(-30 * 3600), now: now) == "yesterday")
    }

    @Test func manualClockMoves() {
        let clock = ManualClock(Date(timeIntervalSince1970: 0))
        clock.advance(90)
        #expect(clock.now == Date(timeIntervalSince1970: 90))
    }
}
