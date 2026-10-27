import Foundation

/// Someone from the owner's contacts, as `people_get` reports them.
public struct PersonCard: Codable, Hashable, Sendable {
    public var name: String
    public var nickname: String?
    /// "mother", "brother", when the contact says so.
    public var relation: String?
    public var birthdayMonth: Int?
    public var birthdayDay: Int?
    public var birthdayYear: Int?
    public var anniversaryMonth: Int?
    public var anniversaryDay: Int?
    public var city: String?
    public var emails: [String]
    public var hasPhone: Bool
    public var note: String?

    public init(
        name: String, nickname: String? = nil, relation: String? = nil, birthdayMonth: Int? = nil, birthdayDay: Int? = nil,
        birthdayYear: Int? = nil, anniversaryMonth: Int? = nil, anniversaryDay: Int? = nil, city: String? = nil,
        emails: [String] = [], hasPhone: Bool = false, note: String? = nil
    ) {
        self.name = name
        self.nickname = nickname
        self.relation = relation
        self.birthdayMonth = birthdayMonth
        self.birthdayDay = birthdayDay
        self.birthdayYear = birthdayYear
        self.anniversaryMonth = anniversaryMonth
        self.anniversaryDay = anniversaryDay
        self.city = city
        self.emails = emails
        self.hasPhone = hasPhone
        self.note = note
    }

    /// The next time a month and day comes around, today included.
    public static func next(month: Int, day: Int, after now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        return calendar.nextDate(
            after: today.addingTimeInterval(-1), matching: DateComponents(month: month, day: day), matchingPolicy: .nextTime)
    }

    /// True when `query` names this person: their name, a part of it, their nickname or relation.
    public func matches(_ query: String) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return false }
        let relationWords: [String: [String]] = [
            "mother": ["mom", "mum", "mother", "mama"], "father": ["dad", "father", "papa"],
            "sister": ["sister", "sis"], "brother": ["brother", "bro"],
        ]
        if let relation = relation?.lowercased() {
            if relation == q || relationWords[relation]?.contains(q) == true { return true }
        }
        if nickname?.lowercased() == q { return true }
        let name = self.name.lowercased()
        return name == q || name.split(separator: " ").contains { $0 == q } || (q.count > 3 && name.contains(q))
    }
}

/// How Ask's tool results read, to Claude (compact text) and to the owner (one
/// trace line under the tool's name).
public enum AskFormat {
    static let bodyLimit = 4_000
    static let threadLimit = 16_000

    public static func search(_ messages: [MailItem], problems: [SourceProblem], query: String, account: String, fmt: Fmt) -> ToolOutcome {
        var lines = ["\(messages.count) message\(messages.count == 1 ? "" : "s"), newest first:"]
        for m in messages {
            let unread = m.unread ? " · unread" : ""
            lines.append(
                "- [\(m.account)] message \(m.id) · thread \(m.threadId) · \(fmt.shortDay(m.date)) \(fmt.time(m.date)) · "
                    + "from \(m.from) · “\(m.subject)”\(unread)\n  \(m.snippet)")
        }
        for problem in problems { lines.append("(\(problem.source) couldn't be searched: \(problem.message))") }
        if messages.isEmpty { lines.append("Nothing matched.") }
        return ToolOutcome(
            text: lines.joined(separator: "\n"),
            trace: "account: \(account) · \(query) · \(messages.count) message\(messages.count == 1 ? "" : "s")")
    }

    public static func thread(_ thread: ThreadResponse, fmt: Fmt) -> ToolOutcome {
        var lines: [String] = []
        var used = 0
        for m in thread.messages {
            var body = m.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.count > bodyLimit { body = String(body.prefix(bodyLimit)) + " […]" }
            if used + body.count > threadLimit { body = "[earlier text left out]" }
            used += body.count
            lines.append(
                "Message \(m.id) · \(fmt.shortDay(m.date)) \(fmt.time(m.date))\nFrom: \(m.from)\nTo: \(m.to)\nSubject: \(m.subject)\n\n\(body)"
            )
        }
        let subject = thread.messages.first?.subject ?? ""
        return ToolOutcome(
            text: "Thread \(thread.threadId) on \(thread.account):\n\n" + lines.joined(separator: "\n\n---\n\n"),
            trace: "\(thread.account) · \(thread.messages.count) message\(thread.messages.count == 1 ? "" : "s") · “\(subject)”")
    }

    public static func agenda(_ agenda: Agenda, from: Date, through last: Date, fmt: Fmt) -> ToolOutcome {
        let calendar = fmt.calendar
        var lines: [String] = []
        var count = 0
        var sources = Set<String>()
        var day = calendar.startOfDay(for: from)
        while day <= last {
            let events = agenda.events(on: day)
            lines.append(fmt.longDay(day))
            if events.isEmpty { lines.append("- nothing") }
            for event in events {
                count += 1
                sources.insert(event.source.label)
                let when = event.isAllDay ? "all day" : fmt.timeRange(event.start, event.end)
                var parts = ["- \(when) · \(BusyOnly.title(for: event, partnerName: agenda.household.partnerName)) [\(event.source.label)]"]
                if event.busyOnly {
                    parts.append("(busy only)")
                } else {
                    if let place = event.location, !place.isEmpty { parts.append("at \(place)") }
                    if event.isWaitingOnMe { parts.append("(invite, not answered)") }
                    if event.myResponse == .tentative { parts.append("(maybe)") }
                    if let service = event.meetingService { parts.append("(\(service))") }
                    if event.isReminder { parts.append("(reminder)") }
                }
                lines.append(parts.joined(separator: " "))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return ToolOutcome(
            text: lines.joined(separator: "\n"),
            trace:
                "\(sources.count) calendar\(sources.count == 1 ? "" : "s") · \(span(from, last, fmt: fmt)) · \(count) event\(count == 1 ? "" : "s")"
        )
    }

    public static func freeTime(_ windows: [DateInterval], from: Date, through last: Date, part: String, fmt: Fmt) -> ToolOutcome {
        var byDay: [(Date, [DateInterval])] = []
        for window in windows {
            let day = fmt.calendar.startOfDay(for: window.start)
            if let i = byDay.firstIndex(where: { $0.0 == day }) { byDay[i].1.append(window) } else { byDay.append((day, [window])) }
        }
        let lines = byDay.map { day, windows in
            fmt.shortDay(day) + ": " + windows.map { fmt.timeRange($0.start, $0.end) }.joined(separator: ", ")
        }
        return ToolOutcome(
            text: lines.isEmpty ? "No open windows." : lines.joined(separator: "\n"),
            trace: "\(span(from, last, fmt: fmt)) · \(part) · \(windows.count) window\(windows.count == 1 ? "" : "s")")
    }

    public static func people(_ people: [PersonCard], query: String, now: Date, fmt: Fmt) -> ToolOutcome {
        guard !people.isEmpty else {
            return ToolOutcome(
                text: "No contact matches “\(query)”. Try their name, or search mail for them.", trace: "\(query) · not found")
        }
        var blocks: [String] = []
        for p in people.prefix(3) {
            var lines = [p.name + (p.nickname.map { " (\"\($0)\")" } ?? "")]
            if let relation = p.relation { lines.append("Relation: \(relation)") }
            if let month = p.birthdayMonth, let day = p.birthdayDay,
                let next = PersonCard.next(month: month, day: day, after: now, calendar: fmt.calendar)
            {
                let age = p.birthdayYear.map { ", turning \(fmt.calendar.component(.year, from: next) - $0)" } ?? ""
                lines.append("Birthday: \(fmt.shortDay(next))\(age)")
            }
            if let month = p.anniversaryMonth, let day = p.anniversaryDay,
                let next = PersonCard.next(month: month, day: day, after: now, calendar: fmt.calendar)
            {
                lines.append("Anniversary: \(fmt.shortDay(next))")
            }
            if let city = p.city { lines.append("Lives in: \(city)") }
            if !p.emails.isEmpty { lines.append("Email: \(p.emails.joined(separator: ", "))") }
            lines.append(p.hasPhone ? "Has a phone number" : "No phone number")
            if let note = p.note, !note.isEmpty { lines.append("Notes: \(note)") }
            blocks.append(lines.joined(separator: "\n"))
        }
        let first = people[0]
        var trace = [first.nickname ?? first.name]
        if let month = first.birthdayMonth, let day = first.birthdayDay,
            let next = PersonCard.next(month: month, day: day, after: now, calendar: fmt.calendar)
        {
            trace.append("birthday \(fmt.shortDay(next))")
        }
        if let city = first.city { trace.append(city) }
        return ToolOutcome(text: blocks.joined(separator: "\n\n"), trace: trace.joined(separator: " · "))
    }

    /// "Nov 1–4", "Oct 30–Nov 2", "Nov 3".
    static func span(_ from: Date, _ last: Date, fmt: Fmt) -> String {
        let calendar = fmt.calendar
        let a = calendar.dateComponents([.month, .day], from: from)
        let b = calendar.dateComponents([.month, .day], from: last)
        let first = Fmt.monthsShort[(a.month ?? 1) - 1]
        if a == b { return "\(first) \(a.day ?? 0)" }
        if a.month == b.month { return "\(first) \(a.day ?? 0)–\(b.day ?? 0)" }
        return "\(first) \(a.day ?? 0)–\(Fmt.monthsShort[(b.month ?? 1) - 1]) \(b.day ?? 0)"
    }
}
