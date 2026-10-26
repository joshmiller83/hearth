import Foundation
import HearthKit

/// A fictional household and its week, for tests, previews and the app's
/// `-UITestFixtures` mode. Every name, address and event here is made up.
public enum Fixtures {
    /// Monday, October 26, 2026, 10:08 AM Eastern: the moment the design shows.
    public static let now: Date = RFC3339.date("2026-10-26T10:08:00-04:00")!

    public static let household = Household(
        ownerName: "Sam",
        ownerAccounts: ["home", "work", "school", "town"],
        primaryAccount: "work",
        partnerName: "Robin",
        partnerAccounts: ["robin"],
        guardedAccounts: ["robin", "kid"],
        familyCalendar: "Family",
        timeZone: "America/New_York",
        town: "Maple Grove",
        latitude: 40.21,
        longitude: -77.0
    )

    public static let accounts: [Account] = [
        Account(alias: "home", email: "sam.home@example.com", name: "Sam Rivera"),
        Account(alias: "work", email: "sam@rivera.example", name: "Sam Rivera"),
        Account(alias: "robin", email: "robin@rivera.example", name: "Robin Rivera"),
        Account(alias: "school", email: "srivera@alumni.example.edu", name: "Sam Rivera"),
        Account(alias: "kid", email: "kid.rivera@example.com", name: "Kid Rivera"),
        Account(alias: "town", email: "sam@maplegrove.example.org", name: "Sam Rivera"),
    ]

    public static var zone: TimeZone { household.zone }

    /// "2026-10-26T11:00" in Eastern time.
    public static func at(_ local: String) -> Date {
        RFC3339.date(local, zone: zone)!
    }

    public static func google(
        _ id: String, _ title: String, _ start: String, _ end: String, account: String = "work",
        calendar: String = "primary", uid: String? = nil, response: RSVP = .none, links: [String] = [],
        allDay: Bool = false, transparent: Bool = false, location: String? = nil
    ) -> AgendaEvent {
        var event = AgendaEvent(
            id: "g:\(account):\(calendar):\(id)",
            source: .google(account: account, calendarId: calendar, calendarName: calendar),
            sourceEventId: id,
            iCalUID: uid,
            title: title,
            start: at(start),
            end: at(end),
            isAllDay: allDay,
            location: location,
            meetingLinks: links,
            myResponse: response,
            organizer: response == .none ? nil : "organizer@example.org",
            attendeeCount: response == .none ? 0 : 6,
            transparent: transparent
        )
        if household.isPartnerAccount(account) { event = BusyOnly.redact(event) }
        return event
    }

    public static func apple(
        _ id: String, _ title: String, _ start: String, _ end: String, calendar: String = "Family",
        uid: String? = nil, allDay: Bool = false
    ) -> AgendaEvent {
        AgendaEvent(
            id: "a:\(id)", source: .apple(calendarId: calendar.lowercased(), calendarName: calendar), sourceEventId: id,
            iCalUID: uid, title: title, start: at(start), end: at(end), isAllDay: allDay)
    }

    /// The design's Monday: a coffee chat, lunch, a weekly sync, a frost reminder,
    /// the partner's book club, and two invites later in the week.
    public static var week: [AgendaEvent] {
        [
            google(
                "coffee", "Coffee chat, agency lead", "2026-10-26T11:00", "2026-10-26T11:30",
                uid: "coffee@example.org", response: .accepted, links: ["https://example.zoom.us/j/123"]),
            apple("lunch", "Lunch with Robin", "2026-10-26T12:15", "2026-10-26T13:00"),
            google(
                "sync", "Module weekly sync", "2026-10-26T15:00", "2026-10-26T15:45", account: "home",
                uid: "sync@example.org", response: .accepted, links: ["https://meet.google.com/abc-defg-hij"]),
            AgendaEvent(
                id: "a:frost", source: .apple(calendarId: "reminders", calendarName: "Reminders"), sourceEventId: "frost",
                title: "Cover the plants, frost tonight", start: at("2026-10-26T17:30"), end: at("2026-10-26T17:30"),
                isReminder: true),
            google("book", "book club", "2026-10-26T18:30", "2026-10-26T20:00", account: "robin", uid: "book@example.org"),
            google(
                "bible", "Bible study", "2026-10-29T19:00", "2026-10-29T20:30", account: "home", calendar: "Small group",
                uid: "bible@example.org"),
            google(
                "huddle", "Leaders huddle", "2026-10-29T19:00", "2026-10-29T20:00", uid: "huddle@example.org",
                response: .needsAction),
            google(
                "mixer", "Alumni mixer", "2026-10-28T20:00", "2026-10-28T21:00", account: "school", uid: "mixer@example.org",
                response: .needsAction, links: ["https://example.zoom.us/j/456"]),
            // The same mixer invite, copied onto the work calendar: the merge keeps one.
            google("mixer-copy", "Alumni mixer", "2026-10-28T20:00", "2026-10-28T21:00", uid: "mixer@example.org"),
            apple("trunk", "Trunk or Treat", "2026-10-31T16:00", "2026-10-31T18:00"),
            apple("birthday", "Jordan's birthday", "2026-10-27", "2026-10-28", calendar: "Birthdays", allDay: true),
            google("brunch", "Neighborhood brunch", "2026-11-01T10:00", "2026-11-01T11:30", account: "home"),
        ]
    }
}
