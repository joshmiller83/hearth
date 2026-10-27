import Foundation
import HearthKit
import HearthKitTestSupport

/// The fictional town's feeds and events, for fixtures.
enum FixtureTown {
    static func event(
        _ id: String, _ feed: String, _ title: String, _ start: String, _ end: String, location: String, free: Bool = false,
        summary: String? = nil
    ) -> FeedEvent {
        FeedEvent(
            id: "\(feed):\(id)", feedId: feed, uid: id, title: title, start: Fixtures.at(start), end: Fixtures.at(end), location: location,
            summary: summary, free: free)
    }

    static let feeds: [Feed] = [
        Feed(
            id: "f-church", name: "Church office email", kind: .email, from: "office@church.example", category: "church",
            addedAt: Fixtures.now,
            checkedAt: Fixtures.now, total: 2, kept: 2),
        Feed(
            id: "f-borough", name: "Borough events page", kind: .page, url: URL(string: "https://borough.example.gov/events"),
            category: "family",
            addedAt: Fixtures.now, checkedAt: Fixtures.now, total: 2, kept: 2),
        Feed(
            id: "f-library", name: "Public library", kind: .ical, url: URL(string: "https://library.example.org/events.ics"),
            category: "family",
            skip: ["storytime", "toddler"], addedAt: Fixtures.now, checkedAt: Fixtures.now, total: 22, kept: 1),
        Feed(
            id: "f-tech", name: "Tech meetup group", kind: .ical, url: URL(string: "https://meetup.example.com/central-tech.ics"),
            category: "tech", addedAt: Fixtures.now, checkedAt: Fixtures.now, total: 1, kept: 1),
    ]

    static let events: [FeedEvent] = [
        event(
            "trunk", "f-church", "Trunk or Treat", "2026-10-31T16:00", "2026-10-31T18:00", location: "Church parking lot",
            summary: "The church office asked you and Robin to cover the 4–5 candy table."),
        event(
            "market", "f-borough", "Last farmers market of the season", "2026-10-31T09:00", "2026-10-31T12:00", location: "Downtown",
            free: true),
        event(
            "author", "f-library", "Author talk at the public library", "2026-11-05T19:00", "2026-11-05T20:00", location: "Main branch",
            free: true),
        event("storytime", "f-library", "Toddler storytime", "2026-11-04T10:00", "2026-11-04T10:30", location: "Main branch", free: true),
        event("harvest", "f-church", "Fall harvest dinner", "2026-11-08T17:30", "2026-11-08T19:30", location: "Fellowship hall"),
        event("meetup", "f-tech", "Tech meetup", "2026-11-10T18:30", "2026-11-10T20:30", location: "Downtown co-working space", free: true),
        event("tree", "f-borough", "Downtown tree lighting", "2026-11-27T18:00", "2026-11-27T19:00", location: "Market St", free: true),
    ]

    /// What the community center's feed holds: three to keep, the rest classes and lunches.
    static func communityCenter(feedId: String) -> [FeedEvent] {
        var events = [
            event("craft", feedId, "Fall craft fair", "2026-11-07T10:00", "2026-11-07T15:00", location: "Community center", free: true),
            event("movie", feedId, "Family movie night", "2026-11-13T18:30", "2026-11-13T20:30", location: "Community center", free: true),
            event("cookies", feedId, "Holiday cookie swap", "2026-11-21T13:00", "2026-11-21T15:00", location: "Community center"),
        ]
        let days = ["2026-10-27", "2026-10-29", "2026-11-03", "2026-11-05", "2026-11-10", "2026-11-12", "2026-11-17"]
        events += days.enumerated().map { index, day in
            event("yoga\(index)", feedId, "Chair yoga", day + "T09:00", day + "T10:00", location: "Community center")
        }
        events += ["2026-11-04", "2026-11-11", "2026-11-18", "2026-11-25"].enumerated().map { index, day in
            event("lunch\(index)", feedId, "Senior lunch", day + "T12:00", day + "T13:00", location: "Community center")
        }
        return events.sorted { $0.start < $1.start }
    }
}
