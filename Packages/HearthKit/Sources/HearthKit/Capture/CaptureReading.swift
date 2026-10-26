import Foundation

/// What Claude reads out of a quick note, a flyer, a page of the paper calendar
/// or a screenshot. Dates and times are local wall-clock text, read in the
/// household's zone, so there's no offset to get wrong.
public struct CaptureReading: Codable, Sendable, Equatable {
    /// One sentence for the recent-captures list: "A flyer for the Fall Craft Fair on Sat, Nov 7."
    public var summary: String
    public var entries: [CaptureEntry]

    public init(summary: String, entries: [CaptureEntry]) {
        self.summary = summary
        self.entries = entries
    }
}

public struct CaptureEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case event
        case reminder
        case birthday
        case anniversary
    }

    public enum Confidence: String, Codable, Sendable {
        case high
        case medium
        case low
    }

    /// "e1", "e2": Claude numbers the entries.
    public var id: String
    public var kind: Kind
    /// Short, sentence case. Someone else's entries start with their name: "Robin: dentist".
    public var title: String
    /// "2026-11-07".
    public var date: String
    /// "10:00", 24-hour; nil for all day.
    public var startTime: String?
    /// "15:00"; nil when unknown (the app uses an hour and says so).
    public var endTime: String?
    public var location: String?
    /// Details worth keeping: a phone number, what to bring.
    public var notes: String?
    public var cost: String?
    public var repeats: Repeat?
    /// Whose it is when it isn't the household's: "Robin". Nil for the owner or the family.
    public var person: String?
    /// Written with a question mark, "maybe", "TBD": goes in as tentative.
    public var tentative: Bool
    public var confidence: Confidence
    /// Assumptions to show the owner: "One hour is a guess", "“Ben 12” read as noon".
    public var guesses: [String]
    /// What to ask when Claude can't decide alone.
    public var question: Question?
    /// The words as written: "Dr Ahn 3:30?".
    public var source: String

    public init(
        id: String, kind: Kind = .event, title: String, date: String, startTime: String? = nil, endTime: String? = nil,
        location: String? = nil, notes: String? = nil, cost: String? = nil, repeats: Repeat? = nil, person: String? = nil,
        tentative: Bool = false, confidence: Confidence = .high, guesses: [String] = [], question: Question? = nil,
        source: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.location = location
        self.notes = notes
        self.cost = cost
        self.repeats = repeats
        self.person = person
        self.tentative = tentative
        self.confidence = confidence
        self.guesses = guesses
        self.question = question
        self.source = source
    }

    public var isAllDay: Bool { startTime == nil }

    public struct Repeat: Codable, Sendable, Equatable {
        public enum Frequency: String, Codable, Sendable {
            case daily
            case weekly
            case monthly
            case yearly
        }

        public var frequency: Frequency
        public var interval: Int
        /// "2026-12-31"; nil repeats until removed.
        public var until: String?

        public init(frequency: Frequency, interval: Int = 1, until: String? = nil) {
            self.frequency = frequency
            self.interval = interval
            self.until = until
        }
    }

    public struct Question: Codable, Sendable, Equatable {
        public var text: String
        public var options: [Option]

        public init(text: String, options: [Option]) {
            self.text = text
            self.options = options
        }
    }

    /// One answer, and what it changes. Fields left nil keep the entry's value.
    public struct Option: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        /// Leave the entry out.
        public var skip: Bool
        public var title: String?
        public var startTime: String?
        public var endTime: String?
        /// True makes it all day (clears the times).
        public var allDay: Bool?
        public var person: String?

        public init(
            id: String, label: String, skip: Bool = false, title: String? = nil, startTime: String? = nil,
            endTime: String? = nil, allDay: Bool? = nil, person: String? = nil
        ) {
            self.id = id
            self.label = label
            self.skip = skip
            self.title = title
            self.startTime = startTime
            self.endTime = endTime
            self.allDay = allDay
            self.person = person
        }
    }

    /// This entry with an answer applied. Nil when the answer skips it.
    public func answering(_ option: Option) -> CaptureEntry? {
        guard !option.skip else { return nil }
        var e = self
        if let title = option.title { e.title = title }
        if option.allDay == true {
            e.startTime = nil
            e.endTime = nil
        }
        if let start = option.startTime { e.startTime = start }
        if let end = option.endTime { e.endTime = end }
        if let person = option.person { e.person = person.isEmpty ? nil : person }
        e.question = nil
        return e
    }

    /// The entry's start and end as instants in `zone`. Without an end, timed
    /// entries last an hour (reminders: a moment) and all-day ones a day.
    public func interval(in zone: TimeZone) -> DateInterval? {
        guard let day = RFC3339.parse(date, zone: zone)?.date else { return nil }
        let calendar = Fmt(zone: zone).calendar
        guard let start = startTime else {
            return DateInterval(start: day, end: calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400))
        }
        guard let startDate = Self.time(start, on: day, calendar: calendar) else { return nil }
        if kind == .reminder { return DateInterval(start: startDate, duration: 0) }
        var endDate = endTime.flatMap { Self.time($0, on: day, calendar: calendar) } ?? startDate.addingTimeInterval(3600)
        if endDate <= startDate { endDate = calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate.addingTimeInterval(86400) }
        return DateInterval(start: startDate, end: endDate)
    }

    static func time(_ text: String, on day: Date, calendar: Calendar) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }
}
