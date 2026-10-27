import Foundation
import HearthKit
import Observation

/// People: the inner circle, their birthdays and anniversaries, Claude's small
/// ways to show up, and the partner planner (with the surprise guard).
@MainActor
@Observable
public final class PeopleModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case working
        case failed(String)
    }

    /// What an idea's step did, for Done, Copy, Open and Undo.
    public struct Ran: Equatable, Sendable {
        public var text: String
        public var note: String?
        public var link: URL?
        public var failed: Bool
        var receipts: [ProposalRunner.Receipt]
    }

    public struct Step: Identifiable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var sub: String
        public var done: Bool
        /// Worked out from the calendars or the plan, not ticked by hand.
        public var automatic: Bool
    }

    struct IdeasCache: Codable {
        var day: String
        var ideas: [PeopleIdeasPrompt.Idea]
    }

    let services: AppServices
    weak var app: AppModel?

    public private(set) var circle: [Person]
    public private(set) var ideas: [PeopleIdeasPrompt.Idea]
    var ideasDay: String?
    public private(set) var ideasPhase: Phase = .idle
    public private(set) var ran: [String: Ran] = [:]
    public private(set) var plan: PartnerPlan
    public private(set) var planPhase: Phase = .idle

    init(services: AppServices) {
        self.services = services
        circle = services.database.load([Person].self, key: StoreKey.people) ?? []
        let cached = services.database.load(IdeasCache.self, key: StoreKey.peopleIdeas)
        ideas = cached?.ideas ?? []
        ideasDay = cached?.day
        plan = services.database.load(PartnerPlan.self, key: StoreKey.partnerPlan) ?? PartnerPlan()
    }

    var now: Date { services.clock.now }
    var household: Household { app?.household ?? .placeholder }
    var agenda: Agenda { app?.plans.agenda ?? Agenda(events: [], household: household) }

    // MARK: The circle

    public var partner: Person? { circle.first(where: \.isPartner) }

    /// Partner first, then everyone else in the order they were added.
    public var ordered: [Person] { circle.filter(\.isPartner) + circle.filter { !$0.isPartner } }

    public func search(_ query: String) async -> [PersonCard] {
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        return (try? await services.people.find(query)) ?? []
    }

    public func add(_ card: PersonCard, partner: Bool = false) {
        let person = Person(card: card, isPartner: partner)
        guard !circle.contains(where: { $0.id == person.id }) else { return }
        circle.append(person)
        saveCircle()
    }

    public func remove(_ person: Person) {
        circle.removeAll { $0.id == person.id }
        saveCircle()
    }

    /// Fills in the partner the first time: from Contacts when they're there.
    public func ensurePartner() async {
        guard partner == nil, let name = household.partnerName, !name.isEmpty else { return }
        if let card = try? await services.people.find(name).first {
            add(card, partner: true)
        } else {
            circle.append(Person(id: "partner", name: name, isPartner: true))
            saveCircle()
        }
    }

    // MARK: Coming up

    public var occasions: [Occasion] { Occasions.upcoming(people: circle, agenda: agenda, now: now) }

    /// "Tue, Nov 3 · mail a card by Thursday", "Sat, Nov 14 · three ideas ready".
    public func line(_ occasion: Occasion) -> String {
        let fmt = household.fmt
        var parts = [fmt.shortDay(occasion.date)]
        if occasion.personId != nil, occasion.personId == partner?.id {
            parts.append(plan.ideas.isEmpty ? "plan it quietly" : "\(Signals.spelled(plan.ideas.count).lowercased()) ideas ready")
        } else if occasion.kind == .birthday, let by = Occasions.mailBy(occasion, now: now, calendar: fmt.calendar) {
            parts.append(
                "mail a card by \(fmt.calendar.isDate(by, inSameDayAs: now) ? "today" : Fmt.weekdaysLong[fmt.calendar.component(.weekday, from: by) - 1])"
            )
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Small ways to show up

    /// Asks Claude for today's ideas (once a day unless `force`).
    public func refreshIdeas(force: Bool = false) async {
        let today = RFC3339.day(now, zone: household.zone)
        if !force, ideasDay == today, !ideas.isEmpty { return }
        guard !circle.isEmpty else { return }
        guard let claude = app?.claude else {
            ideasPhase = .failed(ClaudeError.noKey.description)
            return
        }
        ideasPhase = .working
        // Their recent mail, in one search across every inbox.
        var mail: [MailItem] = []
        let emails = Array(circle.flatMap(\.emails).prefix(12))
        if let relay = app?.relay, !emails.isEmpty {
            let query = "from:(" + emails.joined(separator: " OR ") + ") newer_than:45d"
            mail = (try? await relay.searchMail(GmailSearchRequest(query: query, account: "all", limit: 25)))?.messages ?? []
        }
        let free = agenda.freeWindows(from: now, days: 7, dayStart: 8, dayEnd: 21, minimum: 3600, weekdaysOnly: false)
        let request = PeopleIdeasPrompt.request(
            people: circle, occasions: occasions, mail: mail, free: free, household: household, now: now)
        do {
            let (reply, _) = try await claude.structured(request, as: JSONValue.self)
            ideas = PeopleIdeasPrompt.ideas(reply, household: household, now: now)
            ideasDay = today
            ran = [:]
            try? services.database.save(IdeasCache(day: today, ideas: ideas), key: StoreKey.peopleIdeas, now: now)
            ideasPhase = .idle
        } catch {
            ideasPhase = .failed(AskModel.describe(error))
        }
    }

    /// Runs one step of an idea (the tap is the approval).
    public func run(_ step: AskProposal) async {
        let outcome = await runner(context: .ask).run([step], now: now)
        if let done = outcome.ran.first {
            ran[step.id] = Ran(
                text: ProposalRunner.sentence([done.done]), note: done.kind == .note ? done.text : nil,
                link: done.kind == .link ? done.url : nil,
                failed: false, receipts: outcome.receipts)
        } else {
            ran[step.id] = Ran(text: outcome.failed.first?.1 ?? "That didn't work.", failed: true, receipts: [])
        }
        if ProposalRunner.touchesCalendars(outcome.receipts) { await app?.plans.refresh() }
    }

    public func undo(_ stepId: String) async {
        guard let done = ran[stepId] else { return }
        let problems = await runner(context: .ask).undo(done.receipts, now: now)
        ran[stepId] = problems.isEmpty ? nil : Ran(text: problems.joined(separator: " "), failed: true, receipts: [])
        if ProposalRunner.touchesCalendars(done.receipts) { await app?.plans.refresh() }
    }

    func runner(context: ActionContext) -> ProposalRunner {
        ProposalRunner(services: services, relay: app?.relay, household: household, context: context)
    }

    // MARK: The partner planner

    public var partnerOccasion: Occasion? {
        guard let partner else { return nil }
        let theirs = occasions.filter { $0.personId == partner.id }
        return theirs.first { $0.kind == .anniversary } ?? theirs.first
    }

    /// The evening being planned: the partner's next occasion, or else the next
    /// evening in two weeks that's open for both.
    public var planDay: Date? {
        if let occasion = partnerOccasion { return occasion.date }
        let calendar = household.fmt.calendar
        for offset in 1...14 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
            if PartnerWeek.eveningOpen(agenda: agenda, day: day).open { return day }
        }
        return nil
    }

    public var surpriseGuard: Bool { app?.rules.surpriseGuard ?? true }

    public func setSurpriseGuard(_ on: Bool) {
        guard var rules = app?.rules else { return }
        rules.surpriseGuard = on
        app?.setRules(rules)
    }

    public func addLove(_ text: String) {
        let love = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !love.isEmpty, !plan.loves.contains(love) else { return }
        plan.loves.append(love)
        savePlan()
    }

    public func removeLove(_ love: String) {
        plan.loves.removeAll { $0 == love }
        savePlan()
    }

    /// Three ways to spend the evening, from Claude (once per evening unless `force`).
    public func refreshPlans(force: Bool = false) async {
        guard let partner, let day = planDay else { return }
        let dayKey = RFC3339.day(day, zone: household.zone)
        if !force, plan.day == dayKey, !plan.ideas.isEmpty { return }
        guard let claude = app?.claude else {
            planPhase = .failed(ClaudeError.noKey.description)
            return
        }
        planPhase = .working
        let request = PartnerPlanPrompt.request(
            partner: partner, occasion: partnerOccasion, day: day, loves: plan.loves, household: household, now: now)
        do {
            let (reply, _) = try await claude.structured(request, as: JSONValue.self)
            plan.ideas = PartnerPlanPrompt.plans(reply)
            plan.day = dayKey
            if plan.ideas.first(where: { $0.id == plan.picked }) == nil { plan.picked = plan.ideas.first?.id }
            savePlan()
            planPhase = .idle
        } catch {
            planPhase = .failed(AskModel.describe(error))
        }
    }

    public var picked: PlanIdea? { plan.ideas.first { $0.id == plan.picked } }

    public func pick(_ id: String) {
        guard plan.hold == nil else { return }
        plan.picked = id
        savePlan()
    }

    public func toggleStep(_ id: String) {
        if plan.ticked.contains(id) { plan.ticked.remove(id) } else { plan.ticked.insert(id) }
        savePlan()
    }

    public var steps: [Step] {
        guard let day = planDay else { return [] }
        let fmt = household.fmt
        let weekday = Fmt.weekdaysLong[fmt.calendar.component(.weekday, from: day) - 1]
        let partnerName = partner?.shortName ?? "your partner"
        let evening = PartnerWeek.eveningOpen(agenda: agenda, day: day)
        return [
            Step(
                id: "open",
                label: evening.open ? "\(weekday) evening is open for you both" : "\(weekday) evening: \(evening.blocker ?? "busy")",
                sub: "Checked every calendar, \(partnerName)'s as busy only", done: evening.open, automatic: true),
            Step(id: "plan", label: "Pick the plan", sub: picked?.title ?? "Ideas below", done: picked != nil, automatic: true),
            Step(
                id: "flowers", label: "Flowers for \(weekday) morning", sub: "Ordered and confirmed to your own account only",
                done: plan.ticked.contains("flowers"), automatic: false),
            Step(
                id: "card", label: "Write the card", sub: "Ask can start it from your notes. You finish it by hand.",
                done: plan.ticked.contains("card"), automatic: false),
        ]
    }

    /// "A little thing this week": the partner's busiest day, and a nudge to send a note.
    public var littleThing: (title: String, body: String, remindAt: Date?)? {
        guard let partner, let busiest = PartnerWeek.busiestDay(agenda: agenda, now: now) else { return nil }
        let fmt = household.fmt
        let weekday = Fmt.weekdaysLong[fmt.calendar.component(.weekday, from: busiest.day) - 1]
        let noon = fmt.calendar.date(bySettingHour: 11, minute: 55, second: 0, of: busiest.day)
        return (
            "\(weekday) is \(partner.shortName)'s busiest day: \(busiest.count) things on the calendar.",
            "A short note at lunch, or lunch itself, would land well.", noon.flatMap { $0 > now ? $0 : nil }
        )
    }

    public func remindLittleThing() async {
        guard let thing = littleThing, let at = thing.remindAt, let partner else { return }
        await run(
            AskProposal(
                id: "little", kind: .remind, label: "Remind me to send a note", done: "note reminder set",
                title: "Send \(partner.shortName) a note",
                start: at))
    }

    /// "Plan the Thai dinner".
    public var cta: String { "Plan " + (picked?.short ?? "the evening") }

    public var ctaNote: String {
        guard let day = planDay, let idea = picked, let start = start(of: idea, on: day) else { return "" }
        let fmt = household.fmt
        let when = "\(fmt.weekday(day)) \(fmt.time(start))"
        if let hold = plan.hold {
            return "Held \(fmt.weekday(hold.start)) \(fmt.time(hold.start)) on \(hold.account)@\(surpriseGuard ? " as private" : "")."
        }
        return surpriseGuard
            ? "Holds \(when) on \(household.primaryAccount)@ as private. \(partner?.shortName ?? "Their")'s calendar stays untouched."
            : "Surprise guard is off: the hold on \(household.primaryAccount)@ won't be marked private."
    }

    func start(of idea: PlanIdea, on day: Date) -> Date? {
        let parts = idea.start.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return household.fmt.calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }

    /// Holds the evening on the owner's main calendar, private while the guard is on.
    public func makePlan() async {
        guard plan.hold == nil, let day = planDay, let idea = picked, let start = start(of: idea, on: day) else { return }
        planPhase = .working
        let hold = AskProposal(
            id: "plan", kind: .hold, label: cta, done: "evening held", title: idea.title, start: start,
            end: start.addingTimeInterval(TimeInterval(idea.minutes * 60)), account: household.primaryAccount)
        let outcome = await runner(context: surpriseGuard ? .surprise : .ask).run([hold], now: now)
        if case .hold(let account, let calendarId, let eventId)? = outcome.receipts.first {
            plan.hold = PartnerPlan.Hold(account: account, calendarId: calendarId, eventId: eventId, start: start)
            savePlan()
            planPhase = .idle
            await app?.plans.refresh()
        } else {
            planPhase = .failed(outcome.failed.first?.1 ?? "The hold didn't save.")
        }
    }

    public func undoPlan() async {
        guard let hold = plan.hold else { return }
        planPhase = .working
        let problems = await runner(context: surpriseGuard ? .surprise : .ask).undo(
            [.hold(account: hold.account, calendarId: hold.calendarId, eventId: hold.eventId)], now: now)
        if problems.isEmpty {
            plan.hold = nil
            savePlan()
            planPhase = .idle
            await app?.plans.refresh()
        } else {
            planPhase = .failed(problems.joined(separator: " "))
        }
    }

    // MARK: Plumbing

    func saveCircle() { try? services.database.save(circle, key: StoreKey.people, now: now) }
    func savePlan() { try? services.database.save(plan, key: StoreKey.partnerPlan, now: now) }
}

extension StoreKey {
    public static let people = "people.circle"
    public static let peopleIdeas = "people.ideas"
    public static let partnerPlan = "people.partnerPlan"
}
