import Foundation

/// The morning brief: the parts of Today that take judgment. The layout stays
/// put; the relay asks Opus at 6:30 for these few lines.
public struct Brief: Codable, Hashable, Sendable {
    public var generatedAt: Date
    /// The day it's for, "2026-10-26".
    public var day: String
    /// "Three things need you. The rest can wait."
    public var headline: String
    /// The needs-you item ids, most important first.
    public var order: [String]
    /// One small, specific way to show up for someone today, or nil.
    public var kindIdea: String?
    /// Who it's for ("Robin"), when it's for someone.
    public var kindIdeaFor: String?

    public init(generatedAt: Date, day: String, headline: String, order: [String] = [], kindIdea: String? = nil, kindIdeaFor: String? = nil)
    {
        self.generatedAt = generatedAt
        self.day = day
        self.headline = headline
        self.order = order
        self.kindIdea = kindIdea
        self.kindIdeaFor = kindIdeaFor
    }
}

/// `GET /v1/brief`: today's brief, if it has been written.
public struct BriefResponse: Codable, Hashable, Sendable {
    public var brief: Brief?

    public init(brief: Brief?) {
        self.brief = brief
    }
}

/// `POST /v1/devices`: the phone's APNs token.
public struct DeviceRegistration: Codable, Hashable, Sendable {
    public var token: String
    /// "development" for Xcode installs, "production" for TestFlight and the App Store.
    public var environment: String

    public init(token: String, environment: String) {
        self.token = token
        self.environment = environment
    }
}

/// What goes into a brief: Today's facts, already gathered.
public struct BriefInput: Sendable {
    public struct NeedsYou: Sendable, Equatable {
        public var id: String
        public var text: String

        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    public var now: Date
    public var household: Household
    public var today: [AgendaEvent]
    public var needsYou: [NeedsYou]
    public var queueCounts: [MailQueue: Int]
    public var newMail: Int
    /// Birthdays and anniversaries in the next two weeks.
    public var occasions: [AgendaEvent]
    /// Evenings this week when nobody's calendar is busy.
    public var freeEvenings: [DateInterval]

    public init(
        now: Date, household: Household, today: [AgendaEvent], needsYou: [NeedsYou], queueCounts: [MailQueue: Int], newMail: Int,
        occasions: [AgendaEvent], freeEvenings: [DateInterval]
    ) {
        self.now = now
        self.household = household
        self.today = today
        self.needsYou = needsYou
        self.queueCounts = queueCounts
        self.newMail = newMail
        self.occasions = occasions
        self.freeEvenings = freeEvenings
    }

    /// Gathers the input from the merged agenda and the mail snapshot.
    public static func gather(agenda: Agenda, mail: MailSnapshot?, now: Date) -> BriefInput {
        let household = agenda.household
        let fmt = household.fmt
        var needs: [NeedsYou] = agenda.waitingOnMe(now: now).prefix(6).map { invite in
            var text = "RSVP: \(invite.title), \(fmt.when(invite.start, invite.end, allDay: invite.isAllDay))"
            if let clash = agenda.conflictSentence(for: invite) { text += " (\(clash))" }
            return NeedsYou(id: invite.id, text: text)
        }
        for mail in (mail?.items(in: .reply) ?? []).prefix(8) {
            needs.append(NeedsYou(id: mail.id, text: "Reply: \(mail.item.senderName), “\(mail.item.subject)” (\(mail.tag))"))
        }
        var counts: [MailQueue: Int] = [:]
        for queue in MailQueue.allCases { counts[queue] = mail?.items(in: queue).count ?? 0 }
        let soon = now.addingTimeInterval(14 * 86400)
        let occasions = agenda.events.filter { event in
            event.isAllDay && event.start >= fmt.calendar.startOfDay(for: now) && event.start < soon
                && ["birthday", "anniv"].contains { event.title.lowercased().contains($0) }
        }
        return BriefInput(
            now: now, household: household, today: agenda.events(on: now), needsYou: needs, queueCounts: counts,
            newMail: mail?.newCount ?? 0, occasions: occasions, freeEvenings: agenda.freeEvenings(now: now, days: 7))
    }
}

public enum BriefPrompt {
    public struct Reply: Codable, Sendable, Equatable {
        public var headline: String
        public var order: [String]
        public var kindIdea: String?
        public var kindIdeaFor: String?

        public init(headline: String, order: [String], kindIdea: String?, kindIdeaFor: String?) {
            self.headline = headline
            self.order = order
            self.kindIdea = kindIdea
            self.kindIdeaFor = kindIdeaFor
        }
    }

    public static func system(household: Household) -> String {
        let partner = household.partnerName ?? "their partner"
        return """
            You write \(household.ownerName)'s morning brief for Today, the first screen of Hearth, their household \
            assistant. The screen's layout is fixed; you write only the parts that take judgment:

            - headline: one or two short sentences, at most 16 words, on what matters today and what can wait. \
            Plain and calm: "Three things need you. The rest can wait." Count what truly needs them; not every email does.
            - order: the ids of the needs-you items, most important first. Deadlines, people waiting on an answer and \
            clashes come before newsletters and maybes. Leave out ids that don't really need them today.
            - kindIdea: one small, specific, doable way to show up for someone in their life today or this week, grounded \
            in what you see (an occasion coming up, a free evening they share with \(partner), a long day ahead for \
            someone). One sentence. Null if nothing fits; never generic advice.
            - kindIdeaFor: the person's first name, or null.

            Never repeat private details back in full; this shows on a phone that others may glance at.
            """
    }

    public static func request(_ input: BriefInput) -> ClaudeRequest {
        let fmt = input.household.fmt
        var lines = ["Today is \(fmt.longDay(input.now)), \(fmt.time(input.now))."]
        lines.append("\nToday's calendar:")
        for event in input.today {
            let when = event.isAllDay ? "all day" : fmt.timeRange(event.start, event.end)
            lines.append("- \(when): \(BusyOnly.title(for: event, partnerName: input.household.partnerName)) [\(event.source.label)]")
        }
        if input.today.isEmpty { lines.append("- nothing") }
        lines.append("\nNeeds-you items (id: what):")
        for item in input.needsYou { lines.append("- \(item.id): \(item.text)") }
        if input.needsYou.isEmpty { lines.append("- none") }
        let counts = MailQueue.allCases.map { "\($0.label) \(input.queueCounts[$0] ?? 0)" }.joined(separator: ", ")
        lines.append("\nMail: \(input.newMail) new since the last sweep. Queues: \(counts).")
        if !input.occasions.isEmpty {
            lines.append("\nComing up:")
            for occasion in input.occasions { lines.append("- \(fmt.shortDay(occasion.start)): \(occasion.title)") }
        }
        if !input.freeEvenings.isEmpty {
            lines.append("\nEvenings free for both of them: " + input.freeEvenings.map { fmt.weekday($0.start) }.joined(separator: ", "))
        }
        return ClaudeRequest(
            model: .opus, maxTokens: 8_000, system: system(household: input.household),
            messages: [.user(lines.joined(separator: "\n"))], effort: .medium,
            outputSchema: Schema.object([
                "headline": Schema.string,
                "order": Schema.array(Schema.string),
                "kindIdea": Schema.nullable(Schema.string),
                "kindIdeaFor": Schema.nullable(Schema.string),
            ]))
    }

    public static func brief(_ reply: Reply, input: BriefInput) -> Brief {
        let known = Set(input.needsYou.map(\.id))
        return Brief(
            generatedAt: input.now, day: RFC3339.day(input.now, zone: input.household.zone), headline: reply.headline,
            order: reply.order.filter(known.contains), kindIdea: reply.kindIdea?.isEmpty == true ? nil : reply.kindIdea,
            kindIdeaFor: reply.kindIdeaFor)
    }
}
