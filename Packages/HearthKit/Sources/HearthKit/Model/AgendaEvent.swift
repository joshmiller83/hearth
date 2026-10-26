import Foundation

/// Where an event came from. Google events arrive through the relay; Apple
/// (iCloud) events come from EventKit on the phone; feeds from the relay's
/// feed fetcher.
public enum EventSource: Codable, Hashable, Sendable {
    case google(account: String, calendarId: String, calendarName: String)
    case apple(calendarId: String, calendarName: String)
    case feed(feedId: String, feedName: String)

    /// "work", "Family", "Church events".
    public var label: String {
        switch self {
        case .google(let account, _, let name): name.isEmpty || name == "primary" || name.contains("@") ? account : name
        case .apple(_, let name): name
        case .feed(_, let name): name
        }
    }

    public var account: String? {
        if case .google(let account, _, _) = self { return account }
        return nil
    }

    public var isApple: Bool {
        if case .apple = self { return true }
        return false
    }
}

/// The owner's answer to an invite. `none` means they aren't an attendee (their
/// own event, a subscribed calendar).
public enum RSVP: String, Codable, Sendable, CaseIterable {
    case accepted
    case tentative
    case declined
    case needsAction
    case none

    public init(google: String) {
        self = RSVP(rawValue: google) ?? .none
    }

    /// "Yes", "Maybe", "No".
    public var buttonLabel: String {
        switch self {
        case .accepted: "Yes"
        case .tentative: "Maybe"
        case .declined: "No"
        case .needsAction, .none: ""
        }
    }

    /// "Accepted", "Maybe", "Declined".
    public var pastTense: String {
        switch self {
        case .accepted: "Accepted"
        case .tentative: "Maybe"
        case .declined: "Declined"
        case .needsAction: "Waiting on you"
        case .none: ""
        }
    }
}

/// One event on one calendar, in Hearth's shape. The agenda merges these from
/// every source and keeps one per real-world event.
public struct AgendaEvent: Codable, Hashable, Sendable, Identifiable {
    /// Stable across refreshes: "g:<account>:<calendarId>:<eventId>", "a:<id>", "f:<feed>:<uid>".
    public var id: String
    public var source: EventSource
    /// The id the source knows it by (Google event id, EventKit identifier).
    public var sourceEventId: String
    /// Shared by every copy of one invite, across accounts and apps.
    public var iCalUID: String?
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var meetingLinks: [String]
    public var myResponse: RSVP
    public var organizer: String?
    public var attendeeCount: Int
    /// A partner's event: shown as "<name> is busy: <title>", read-only, details dropped.
    public var busyOnly: Bool
    /// Doesn't block time ("free" in Google, availability free in EventKit).
    public var transparent: Bool
    public var url: String?
    /// Other copies of this event that the merge folded into it.
    public var alsoOn: [EventSource]
    /// A reminder-style entry with no end (the design's "5:30 PM · reminder").
    public var isReminder: Bool

    public init(
        id: String,
        source: EventSource,
        sourceEventId: String,
        iCalUID: String? = nil,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        meetingLinks: [String] = [],
        myResponse: RSVP = .none,
        organizer: String? = nil,
        attendeeCount: Int = 0,
        busyOnly: Bool = false,
        transparent: Bool = false,
        url: String? = nil,
        alsoOn: [EventSource] = [],
        isReminder: Bool = false
    ) {
        self.id = id
        self.source = source
        self.sourceEventId = sourceEventId
        self.iCalUID = iCalUID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.meetingLinks = meetingLinks
        self.myResponse = myResponse
        self.organizer = organizer
        self.attendeeCount = attendeeCount
        self.busyOnly = busyOnly
        self.transparent = transparent
        self.url = url
        self.alsoOn = alsoOn
        self.isReminder = isReminder
    }

    /// An invite still waiting on the owner's answer.
    public var isWaitingOnMe: Bool { myResponse == .needsAction }

    /// Takes up the owner's time: not declined or still unanswered, not marked
    /// free, not all-day, not a reminder.
    public var blocksTime: Bool {
        !transparent && myResponse != .declined && myResponse != .needsAction && !isAllDay && !isReminder
    }

    public func overlaps(_ other: AgendaEvent) -> Bool {
        start < other.end && other.start < end
    }

    /// The meeting service in the first link: "Zoom", "Meet", "Teams", "Webex".
    public var meetingService: String? {
        guard let link = meetingLinks.first?.lowercased() else { return nil }
        if link.contains("zoom.us") { return "Zoom" }
        if link.contains("meet.google.com") { return "Meet" }
        if link.contains("teams.microsoft.com") { return "Teams" }
        if link.contains("webex.com") { return "Webex" }
        return "call"
    }
}

/// A calendar Hearth can read, for the Sources screen and the RSVP/hold routing.
public struct CalendarInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var account: String?
    public var name: String
    public var isPrimary: Bool
    public var accessRole: String

    public init(id: String, account: String?, name: String, isPrimary: Bool = false, accessRole: String = "") {
        self.id = id
        self.account = account
        self.name = name
        self.isPrimary = isPrimary
        self.accessRole = accessRole
    }
}
