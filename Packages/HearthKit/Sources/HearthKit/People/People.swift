import Foundation

/// A birthday or an anniversary: month and day, and the year when it's known.
public struct MonthDay: Codable, Hashable, Sendable {
    public var month: Int
    public var day: Int
    public var year: Int?

    public init(month: Int, day: Int, year: Int? = nil) {
        self.month = month
        self.day = day
        self.year = year
    }

    /// The next time it comes around, today included.
    public func next(after now: Date, calendar: Calendar) -> Date? {
        PersonCard.next(month: month, day: day, after: now, calendar: calendar)
    }
}

/// Someone in the owner's inner circle. Kept on the phone; Claude sees it only
/// when the owner asks for ideas.
public struct Person: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var nickname: String?
    public var relation: String?
    public var isPartner: Bool
    public var birthday: MonthDay?
    public var anniversary: MonthDay?
    public var emails: [String]
    public var city: String?
    /// The owner's own notes. For the partner, the things they love.
    public var notes: [String]

    public init(
        id: String, name: String, nickname: String? = nil, relation: String? = nil, isPartner: Bool = false, birthday: MonthDay? = nil,
        anniversary: MonthDay? = nil, emails: [String] = [], city: String? = nil, notes: [String] = []
    ) {
        self.id = id
        self.name = name
        self.nickname = nickname
        self.relation = relation
        self.isPartner = isPartner
        self.birthday = birthday
        self.anniversary = anniversary
        self.emails = emails
        self.city = city
        self.notes = notes
    }

    /// Someone from Contacts.
    public init(card: PersonCard, isPartner: Bool = false) {
        self.init(
            id: card.name.lowercased(), name: card.name, nickname: card.nickname, relation: card.relation, isPartner: isPartner,
            birthday: card.birthdayMonth.flatMap { m in card.birthdayDay.map { MonthDay(month: m, day: $0, year: card.birthdayYear) } },
            anniversary: card.anniversaryMonth.flatMap { m in card.anniversaryDay.map { MonthDay(month: m, day: $0) } },
            emails: card.emails, city: card.city)
    }

    /// What the owner calls them: "Mom", "Robin".
    public var shortName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        if let word = ["mother": "Mom", "father": "Dad"][relation?.lowercased() ?? ""] { return word }
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    public var initial: String { String(shortName.prefix(1)).uppercased() }
}

/// A birthday or anniversary coming up.
public struct Occasion: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case birthday
        case anniversary
    }

    public var id: String
    public var kind: Kind
    public var personId: String?
    /// "Mom’s birthday", "Anniversary with Robin".
    public var title: String
    /// The day, at its start.
    public var date: Date
    public var daysAway: Int

    public init(id: String, kind: Kind, personId: String?, title: String, date: Date, daysAway: Int) {
        self.id = id
        self.kind = kind
        self.personId = personId
        self.title = title
        self.date = date
        self.daysAway = daysAway
    }
}

public enum Occasions {
    /// The inner circle's birthdays and anniversaries, plus any on the
    /// calendars (the Birthdays calendar) that nobody in the circle covers.
    public static func upcoming(people: [Person], agenda: Agenda, now: Date, days: Int = 60) -> [Occasion] {
        let calendar = agenda.household.fmt.calendar
        let today = calendar.startOfDay(for: now)
        func away(_ date: Date) -> Int { calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0 }
        var out: [Occasion] = []
        for person in people {
            if let date = person.birthday?.next(after: now, calendar: calendar), away(date) <= days {
                out.append(
                    Occasion(
                        id: "birthday:\(person.id)", kind: .birthday, personId: person.id, title: "\(person.shortName)’s birthday",
                        date: date, daysAway: away(date)))
            }
            if let date = person.anniversary?.next(after: now, calendar: calendar), away(date) <= days {
                let title = person.isPartner ? "Anniversary with \(person.shortName)" : "\(person.shortName)’s anniversary"
                out.append(
                    Occasion(
                        id: "anniversary:\(person.id)", kind: .anniversary, personId: person.id, title: title, date: date,
                        daysAway: away(date)))
            }
        }
        for event in agenda.events where event.isAllDay && event.start >= today && away(event.start) <= days {
            let lower = event.title.lowercased()
            guard lower.contains("birthday") || lower.contains("anniversary") else { continue }
            if out.contains(where: { calendar.isDate($0.date, inSameDayAs: event.start) }) { continue }
            out.append(
                Occasion(
                    id: "event:\(event.id)", kind: lower.contains("birthday") ? .birthday : .anniversary, personId: nil, title: event.title,
                    date: calendar.startOfDay(for: event.start), daysAway: away(event.start)))
        }
        return out.sorted { $0.date < $1.date }
    }

    /// The last day a card can go in the mail and still arrive (five days ahead), while that's still to come.
    public static func mailBy(_ occasion: Occasion, now: Date, calendar: Calendar) -> Date? {
        guard let by = calendar.date(byAdding: .day, value: -5, to: occasion.date), by >= calendar.startOfDay(for: now) else { return nil }
        return by
    }
}

/// "Small ways to show up": a few specific ideas for the inner circle, from the
/// owner's own mail and calendars. Each comes with steps Hearth can take, the
/// same kind Ask proposes, run after a tap.
public enum PeopleIdeasPrompt {
    public struct Idea: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        /// Their short name: "Dad".
        public var person: String
        /// "From Dad's last two emails".
        public var source: String
        public var title: String
        public var body: String
        public var actions: [AskProposal]

        public init(id: String, person: String, source: String, title: String, body: String, actions: [AskProposal]) {
            self.id = id
            self.person = person
            self.source = source
            self.title = title
            self.body = body
            self.actions = actions
        }
    }

    public static func system(household: Household) -> String {
        let owner = household.ownerName.isEmpty ? "the owner" : household.ownerName
        return """
            You suggest small, specific ways for \(owner) to show up for the people closest to them this week: a note \
            when someone's going through something, a call on a birthday, a nudge to watch the game with Dad.

            - Use only what's in the message: their mail, calendars, occasions and \(owner)'s own notes. Never guess \
            about anyone's life, health or plans beyond what's written there.
            - Refer to people by the name given, not by pronouns you'd have to guess.
            - Each idea: person (the name as given), source (a few words on where it comes from: "From Dad's last two \
            emails", "Mom's birthday is Tuesday"), title (one line), body (one or two sentences: what to do and when, \
            using the free time listed), and one or two actions Hearth can take after a tap.
            - Actions are remind (a reminder on the phone), hold (private time on \(owner)'s calendar), note (text to \
            copy, written in \(owner)'s voice, short and warm), or link (an https page). No replies.
            - Up to three ideas, best first. Fewer is fine, and none when nothing is grounded.
            """
    }

    public static func request(
        people: [Person], occasions: [Occasion], mail: [MailItem], free: [DateInterval], household: Household, now: Date
    ) -> ClaudeRequest {
        let fmt = household.fmt
        var lines = ["Today is \(fmt.longDay(now)), \(fmt.time(now))."]
        lines.append("\nInner circle:")
        for person in people {
            var parts = ["- \(person.shortName)"]
            if person.shortName != person.name { parts.append("(\(person.name))") }
            if person.isPartner { parts.append("· partner") } else if let relation = person.relation { parts.append("· \(relation)") }
            if let city = person.city { parts.append("· lives in \(city)") }
            if !person.notes.isEmpty { parts.append("· notes: " + person.notes.joined(separator: "; ")) }
            lines.append(parts.joined(separator: " "))
        }
        if !occasions.isEmpty {
            lines.append("\nComing up:")
            for occasion in occasions { lines.append("- \(occasion.title): \(fmt.shortDay(occasion.date)), in \(occasion.daysAway) days") }
        }
        lines.append("\nRecent mail from them, newest first:")
        for item in mail.prefix(30) {
            lines.append("- \(fmt.shortDay(item.date)) · \(item.senderName): “\(item.subject)” \(item.snippet)")
        }
        if mail.isEmpty { lines.append("- none") }
        lines.append("\n\(household.ownerName)'s free time this week:")
        for window in free.prefix(12) { lines.append("- \(fmt.shortDay(window.start)) \(fmt.timeRange(window.start, window.end))") }
        if free.isEmpty { lines.append("- none found") }
        return ClaudeRequest(
            model: .opus, maxTokens: 8_000, system: system(household: household), messages: [.user(lines.joined(separator: "\n"))],
            effort: .medium,
            outputSchema: Schema.object([
                "ideas": Schema.array(
                    Schema.object([
                        "person": Schema.string, "source": Schema.string, "title": Schema.string, "body": Schema.string,
                        "actions": Schema.array(AskPrompt.actionSchema),
                    ]))
            ]))
    }

    /// The reply's ideas, their steps checked the way Ask's are.
    public static func ideas(_ reply: JSONValue, household: Household, now: Date) -> [Idea] {
        (reply["ideas"]?.arrayValue ?? []).prefix(4).enumerated().compactMap { index, raw in
            guard let title = raw["title"]?.stringValue, !title.isEmpty else { return nil }
            let id = "idea\(index + 1)"
            let steps = AskProposal.parse(["actions": raw["actions"] ?? []], household: household, now: now).proposals
                .filter { $0.kind != .reply }
                .map { step in
                    var step = step
                    step.id = id + "-" + step.id
                    return step
                }
            return Idea(
                id: id, person: raw["person"]?.stringValue ?? "", source: raw["source"]?.stringValue ?? "", title: title,
                body: raw["body"]?.stringValue ?? "", actions: steps)
        }
    }
}

/// One way to spend the partner's occasion, from "Pick the plan".
public struct PlanIdea: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Where it comes from: "From your list: Thai food", "Low-key".
    public var tag: String
    public var title: String
    public var sub: String
    /// For the button: "Plan the Thai dinner".
    public var short: String
    /// When it starts, "18:30", and how long to hold.
    public var start: String
    public var minutes: Int

    public init(id: String, tag: String, title: String, sub: String, short: String, start: String, minutes: Int) {
        self.id = id
        self.tag = tag
        self.title = title
        self.sub = sub
        self.short = short
        self.start = start
        self.minutes = minutes
    }
}

/// The partner planner's state, kept on the phone.
public struct PartnerPlan: Codable, Hashable, Sendable {
    /// The day the ideas are for, "2026-11-14".
    public var day: String?
    public var ideas: [PlanIdea]
    public var picked: String?
    /// Steps the owner ticked by hand.
    public var ticked: Set<String>
    /// The things the partner loves, as the owner tells it.
    public var loves: [String]
    /// The private hold made for the plan, for Undo.
    public var hold: Hold?

    public struct Hold: Codable, Hashable, Sendable {
        public var account: String
        public var calendarId: String
        public var eventId: String
        public var start: Date

        public init(account: String, calendarId: String, eventId: String, start: Date) {
            self.account = account
            self.calendarId = calendarId
            self.eventId = eventId
            self.start = start
        }
    }

    public init(
        day: String? = nil, ideas: [PlanIdea] = [], picked: String? = nil, ticked: Set<String> = [], loves: [String] = [], hold: Hold? = nil
    ) {
        self.day = day
        self.ideas = ideas
        self.picked = picked
        self.ticked = ticked
        self.loves = loves
        self.hold = hold
    }
}

public enum PartnerPlanPrompt {
    public static func system(household: Household) -> String {
        let owner = household.ownerName.isEmpty ? "the owner" : household.ownerName
        let partner = household.partnerName ?? "their partner"
        return """
            You help \(owner) plan something for \(partner), as a surprise. Offer three different ways to spend the \
            evening named in the message.

            - Ground ideas in the things \(owner) says \(partner) loves. When an idea needs a detail you don't have, say \
            so in its tag ("Needs one detail from you") rather than inventing it. Make one of them low-key.
            - Refer to \(partner) by name, not by pronouns you'd have to guess.
            - Nothing that would message or notify \(partner): it's a surprise.
            - Each plan: tag (a few words on where it comes from: "From your list: Thai food", "Low-key"), title (one \
            line), sub (one or two sentences: the time and the shape of the evening), short (how it reads in "Plan …": \
            "the Thai dinner"), start (HH:MM, 24-hour) and minutes (how long to keep the evening).
            """
    }

    public static func request(partner: Person, occasion: Occasion?, day: Date, loves: [String], household: Household, now: Date)
        -> ClaudeRequest
    {
        let fmt = household.fmt
        var lines = ["Today is \(fmt.longDay(now))."]
        lines.append("The evening: \(fmt.longDay(day))" + (occasion.map { " (\($0.title))" } ?? ""))
        if !household.town.isEmpty { lines.append("They live in \(household.town).") }
        lines.append("Things \(partner.shortName) loves, as \(household.ownerName) tells it:")
        for love in loves { lines.append("- \(love)") }
        if loves.isEmpty { lines.append("- nothing written down yet") }
        return ClaudeRequest(
            model: .opus, maxTokens: 6_000, system: system(household: household), messages: [.user(lines.joined(separator: "\n"))],
            effort: .medium,
            outputSchema: Schema.object([
                "plans": Schema.array(
                    Schema.object([
                        "tag": Schema.string, "title": Schema.string, "sub": Schema.string, "short": Schema.string,
                        "start": Schema.string("HH:MM, 24-hour."), "minutes": Schema.integer,
                    ]))
            ]))
    }

    public static func plans(_ reply: JSONValue) -> [PlanIdea] {
        (reply["plans"]?.arrayValue ?? []).prefix(3).enumerated().compactMap { index, raw in
            guard let title = raw["title"]?.stringValue, !title.isEmpty else { return nil }
            let start = raw["start"]?.stringValue ?? "18:30"
            let valid = start.split(separator: ":").count == 2 && start.split(separator: ":").allSatisfy { Int($0) != nil }
            return PlanIdea(
                id: "plan\(index + 1)", tag: raw["tag"]?.stringValue ?? "", title: title, sub: raw["sub"]?.stringValue ?? "",
                short: raw["short"]?.stringValue ?? title, start: valid ? start : "18:30",
                minutes: min(max(raw["minutes"]?.intValue ?? 150, 30), 360))
        }
    }
}

public enum PartnerWeek {
    /// Whether an evening (5 to 10 PM) is open for the owner and the partner,
    /// and if not, what's in the way.
    public static func eveningOpen(agenda: Agenda, day: Date) -> (open: Bool, blocker: String?) {
        let calendar = agenda.household.fmt.calendar
        guard let from = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: day),
            let to = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: day)
        else { return (true, nil) }
        let blocking = agenda.events.filter { $0.blocksTime && !$0.isAllDay && $0.start < to && $0.end > from }
        guard let first = blocking.first else { return (true, nil) }
        return (false, BusyOnly.title(for: first, partnerName: agenda.household.partnerName))
    }

    /// The partner's busiest day in the next week, by their busy-only events, when it has three or more.
    public static func busiestDay(agenda: Agenda, now: Date) -> (day: Date, count: Int)? {
        let calendar = agenda.household.fmt.calendar
        let today = calendar.startOfDay(for: now)
        var best: (Date, Int)?
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let count = agenda.events(on: day).filter { $0.busyOnly && !$0.isAllDay }.count
            if count >= 3, count > (best?.1 ?? 0) { best = (day, count) }
        }
        return best
    }
}
