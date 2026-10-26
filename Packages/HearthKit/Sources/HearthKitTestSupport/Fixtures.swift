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

// MARK: - Mail

extension Fixtures {
    static func mail(
        _ id: String, _ account: String, _ from: String, _ subject: String, _ snippet: String, _ local: String,
        labels: [String] = ["INBOX", "UNREAD"], github: String? = nil, listId: String? = nil
    ) -> MailItem {
        MailItem(
            id: id, threadId: "t-" + id, account: account, from: from, to: "", subject: subject, snippet: snippet,
            date: at(local), labels: labels, unread: labels.contains("UNREAD"), githubReason: github, listId: listId)
    }

    /// A Monday morning's inboxes, every sender fictional.
    public static var inbox: [MailItem] {
        [
            mail(
                "m1", "work", "Dana Whitfield <dana@northbeam.example>", "Next steps: Senior Engineer",
                "Thanks again for Friday. Could you share a few windows for a 90-minute panel with engineering and product?",
                "2026-10-26T08:12"),
            mail(
                "m2", "home", "Church Office <office@church.example>", "Trunk or Treat shifts",
                "Could you and Robin take the 4–5 slot at the candy table on Saturday?", "2026-10-26T07:48"),
            mail(
                "m3", "home", "Mom <mom@example.com>", "Thanksgiving plans??",
                "Are you all coming Wednesday night or Thursday morning? Dad wants to know.", "2026-10-25T16:20"),
            mail(
                "m4", "school", "Alumni Association <calendar-notification@google.com>",
                "Invitation: Virtual mixer @ Wed Oct 28, 2026 8pm - 9pm (EDT)", "Reply to RSVP.", "2026-10-24T11:00"),
            mail(
                "m5", "work", "Northbeam Talent <no-reply@us.greenhouse-mail.io>", "Application received: Senior Engineer",
                "We've received your application and will be in touch.", "2026-10-26T06:02"),
            mail(
                "m6", "work", "Civic Labs Hiring <jobs@civiclabs.example>", "Thanks for applying",
                "Your application for Platform Engineer is in review.", "2026-10-26T05:40"),
            mail(
                "m7", "work", "LinkedIn Job Alerts <jobalerts-noreply@linkedin.com>", "12 new engineering roles near you",
                "Two match your saved search.", "2026-10-25T09:00"),
            mail(
                "m8", "home", "Sam Rivera <notifications@github.com>", "Re: [module] Batch modify (#212)", "Merged.",
                "2026-10-26T07:15", github: "subscribed"),
            mail(
                "m9", "home", "Riley <notifications@github.com>", "Re: [module] Docs pass (#215)", "LGTM.",
                "2026-10-26T07:05", github: "comment"),
            mail(
                "m10", "home", "Kevin <notifications@github.com>", "[module] Review requested on #218", "Kevin requested your review.",
                "2026-10-26T06:50", github: "review_requested"),
            mail(
                "m11", "work", "Your Bank <alerts@bank.example>", "Your October statement is ready",
                "Your statement for the account ending in 42 is available.", "2026-10-26T06:30"),
            mail(
                "m12", "town", "Maple Grove Daily <news@daily.example>", "Monday: Council meeting, Route 15 work",
                "Today's top stories.", "2026-10-26T06:00", labels: ["INBOX", "UNREAD", "CATEGORY_UPDATES"], listId: "<daily.example>"),
            mail(
                "m13", "home", "Parcel Updates <ship@carrier.example>", "Delivered: 2 packages", "Left at front door at 3:14 PM.",
                "2026-10-25T15:20"),
            mail(
                "m14", "robin", "Home Goods <deals@homegoods.example>", "Fall sale ends tonight", "Up to 40% off throws.",
                "2026-06-20T05:00", labels: ["INBOX", "UNREAD", "CATEGORY_PROMOTIONS"]),
            mail("m15", "home", "Google <no-reply@accounts.google.com>", "Security alert", "A new sign-in on Mac.", "2026-10-26T04:10"),
            mail(
                "m16", "kid", "Coach Martinez <coach@league.example>", "Practice moved to Thursday",
                "Field 3 is closed, so we'll practice Thursday at 5:30.", "2026-10-25T18:45", labels: ["INBOX"]),
        ]
    }
}
