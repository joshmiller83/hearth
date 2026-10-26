import Foundation
import HearthKit

/// What the Today screen shows, worked out from the other models. A value, not
/// state: the screen rebuilds it whenever they change.
public struct TodaySummary: Sendable, Equatable {
    public struct NeedsYou: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable { case invite, reply, signal }
        public var id: String
        public var kind: Kind
        public var title: String
        public var detail: String
    }

    public var dateLine: String
    public var greeting: String
    public var sweepLine: String
    public var nextUp: AgendaEvent?
    public var nextUpLabel: String?
    public var nextUpMeta: String?
    public var needsYou: [NeedsYou]
    /// The next few days' plans, after today.
    public var comingUp: [AgendaEvent]
    /// Queue counts for "Inbox, triaged", in queue order; nil before the first sweep.
    public var triage: [(queue: MailQueue, count: Int)]?
    public var newMail: Int
    /// The brief's kind idea, unless set aside today.
    public var kindIdea: String?
    public var kindIdeaFor: String?

    public static func == (a: TodaySummary, b: TodaySummary) -> Bool {
        a.dateLine == b.dateLine && a.greeting == b.greeting && a.sweepLine == b.sweepLine && a.nextUp == b.nextUp
            && a.needsYou == b.needsYou && a.comingUp == b.comingUp && a.newMail == b.newMail
            && a.triage?.map(\.count) == b.triage?.map(\.count) && a.kindIdea == b.kindIdea
    }

    @MainActor
    public static func make(app: AppModel) -> TodaySummary {
        let now = app.now
        let household = app.household
        let fmt = household.fmt
        let plans = app.plans
        let agenda = plans.agenda

        let hour = fmt.calendar.component(.hour, from: now)
        let part = hour < 12 ? "morning" : hour < 17 ? "afternoon" : "evening"
        let greeting = household.ownerName == Household.placeholder.ownerName ? "Good \(part)." : "Good \(part), \(household.ownerName)."

        var needs: [NeedsYou] = []
        for invite in agenda.waitingOnMe(now: now) where plans.replies[invite.id] == nil {
            var detail = fmt.weekday(invite.start) + " " + fmt.time(invite.start, compact: true)
            if let other = agenda.conflicts(with: invite).first { detail += " · overlaps \(other.title)" }
            needs.append(NeedsYou(id: invite.id, kind: .invite, title: "RSVP: \(invite.title)", detail: detail))
        }

        let mail = app.inbox.snapshot
        for reply in (mail?.items(in: .reply) ?? []).prefix(3) {
            let item = reply.item
            needs.append(
                NeedsYou(
                    id: reply.id, kind: .reply, title: "\(item.senderName): \(item.subject)",
                    detail: "\(reply.tag) · \(item.account) · \(app.inbox.time(item.date))"))
        }

        // The brief decides the order; anything it didn't rank keeps its place after.
        if let order = app.todaysBrief?.order, !order.isEmpty {
            let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            needs = needs.enumerated().sorted { a, b in
                (rank[a.element.id] ?? order.count + a.offset) < (rank[b.element.id] ?? order.count + b.offset)
            }.map(\.element)
        }

        var sweep = "Add the relay in Sources to bring in mail and Google calendars."
        if let fetched = plans.fetchedAt {
            let count = needs.count
            let things = count == 0 ? "Nothing needs you right now." : count == 1 ? "One thing needs you." : "\(count) things need you."
            let accounts = app.health?.accounts?.count
            let what =
                mail != nil
                ? "Swept \(accounts ?? mail!.accounts.count) inboxes and every calendar"
                : accounts.map { "Checked \($0) accounts and every calendar" }
                    ?? "Checked every calendar"
            sweep = "\(what) at \(fmt.time(max(fetched, mail?.generatedAt ?? fetched))). \(app.todaysBrief?.headline ?? things)"
        }

        let next = agenda.nextUp(now: now)
        var label: String?
        var meta: String?
        if let next {
            let minutes = fmt.minutesUntil(next.start, now: now)
            label = minutes <= 0 ? "Next up · now" : "Next up · " + fmt.relative(next.start, now: now)
            var parts: [String] = []
            if let service = next.meetingService { parts.append(service) }
            if let account = next.source.account { parts.append("landed on \(account)@") } else { parts.append(next.source.label) }
            meta = parts.joined(separator: " · ")
        }

        let calendar = fmt.calendar
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let horizon = calendar.date(byAdding: .day, value: 6, to: tomorrow) ?? now
        let coming = agenda.events
            .filter { $0.start >= tomorrow && $0.start < horizon && !$0.busyOnly && $0.myResponse != .declined && !$0.isWaitingOnMe }
            .prefix(4)

        return TodaySummary(
            dateLine: fmt.longDay(now).uppercased(),
            greeting: greeting,
            sweepLine: sweep,
            nextUp: next,
            nextUpLabel: label,
            nextUpMeta: meta,
            needsYou: needs,
            comingUp: Array(coming),
            triage: mail.map { snapshot in MailQueue.allCases.map { ($0, snapshot.items(in: $0).count) } },
            newMail: mail?.newCount ?? 0,
            kindIdea: app.kindIdeaDismissed ? nil : app.todaysBrief?.kindIdea,
            kindIdeaFor: app.todaysBrief?.kindIdeaFor
        )
    }
}
