import Foundation
import HearthKit
import Observation

/// Ask Hearth: a conversation with Opus over mail, calendars and contacts.
/// Claude reads through tools and shows its work; when something should be
/// done it proposes steps, the owner picks which to run, and Undo takes them
/// back where that's still possible.
@MainActor
@Observable
public final class AskModel {
    /// A reply waits this long at the relay before it sends, so Undo can stop it.
    public static let replyDelay: TimeInterval = 30

    /// One tool call in "Checked N sources".
    public struct TraceLine: Identifiable, Equatable, Sendable {
        public let id: String
        public var tool: String
        public var detail: String
        public var finished: Bool
    }

    public enum Phase: Equatable, Sendable {
        case working
        case answered
        case failed(String)
    }

    /// Where the proposed steps stand.
    public enum Run: Equatable, Sendable {
        /// Shown, waiting for a tap.
        case waiting
        case running
        /// "Card note drafted, Thursday reminder set."
        case done(String)
        case failed(String)
    }

    enum Executed: Equatable, Sendable {
        case reminder(String)
        case event(String)
        case hold(account: String, calendarId: String, eventId: String)
        /// Waiting at the relay (a reply's 30 seconds): cancelling stops it.
        case pending(actionId: String, label: String)
        /// Done at the relay and not reversible.
        case sent(label: String)
    }

    public struct Turn: Identifiable, Equatable, Sendable {
        public let id: Int
        public var question: String
        public var trace: [TraceLine] = []
        public var seconds: TimeInterval?
        public var answer = ""
        public var proposals: [AskProposal] = []
        public var selected: Set<String> = []
        public var phase: Phase = .working
        public var run: Run = .waiting
        /// What a finished run left to copy and open.
        public var notes: [AskProposal] = []
        public var links: [AskProposal] = []
        /// What Undo couldn't take back.
        public var undoProblem: String?
        /// What became of the proposals, for Claude.
        var outcome: String?
        var executed: [Executed] = []

        public var chosenCount: Int { proposals.filter { selected.contains($0.id) }.count }
    }

    let services: AppServices
    weak var app: AppModel?

    public internal(set) var turns: [Turn] = []
    public var draft = ""
    /// The whole conversation as Claude saw it: append-only, thinking included.
    private(set) var transcript: [ClaudeMessage] = []
    /// propose_actions calls the transcript ends on, with the turn that made them:
    /// their results open the next question (and stay owed if that one fails).
    private var owed: [(call: String, turn: Int)] = []

    init(services: AppServices) {
        self.services = services
    }

    var now: Date { services.clock.now }
    var household: Household { app?.household ?? .placeholder }
    var accounts: [String] { app?.health?.accounts?.map(\.alias) ?? household.ownerAccounts }

    public var isWorking: Bool { turns.last?.phase == .working }

    /// Starting points for the chips above the field.
    public var suggestions: [String] {
        var chips = ["What needs me this week?"]
        if let replies = app?.inbox.snapshot?.items(in: .reply).count, replies > 0 { chips.append("Draft the replies waiting on me") }
        chips += ["Who haven't I talked to lately?", "When am I free this week?"]
        return chips
    }

    public func startOver() {
        guard !isWorking else { return }
        turns = []
        transcript = []
        owed = []
    }

    // MARK: Asking

    /// Sends the draft (or `text`) and streams the answer in.
    public func ask(_ text: String? = nil) async {
        let question = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isWorking else { return }
        draft = ""
        let id = (turns.last?.id ?? 0) + 1
        turns.append(Turn(id: id, question: question))
        guard let claude = app?.claude else {
            update(id) { $0.phase = .failed(ClaudeError.noKey.description) }
            return
        }
        // Claude is owed what became of its last proposals.
        let results: [ContentBlock] = owed.map { item in
            let outcome = turns.first { $0.id == item.turn }?.outcome
            return .toolResult(id: item.call, text: outcome ?? AskOutcome.text(ran: [], skipped: [], failed: [], undone: false))
        }
        let started = now
        let request = AskPrompt.request(
            transcript: transcript + [AskPrompt.turn(question: question, owed: results)], household: household, accounts: accounts,
            now: started)
        var paragraphBreak = false
        do {
            for try await event in ToolLoop(client: claude).run(request, toolbox: toolbox(), terminal: [AskTool.proposeActions]) {
                switch event {
                case .stream(.textDelta(let text)):
                    update(id) { turn in
                        if paragraphBreak, !turn.answer.isEmpty { turn.answer += "\n\n" }
                        turn.answer += text
                    }
                    paragraphBreak = false
                case .toolStarted(let call) where call.name != AskTool.proposeActions:
                    update(id) { $0.trace.append(TraceLine(id: call.id, tool: call.name, detail: "", finished: false)) }
                case .toolFinished(let call, let outcome):
                    paragraphBreak = true
                    if call.name == AskTool.proposeActions {
                        let parsed = AskProposal.parse(call.input, household: household, now: now)
                        update(id) { turn in
                            turn.proposals = parsed.proposals
                            // Links are extras; everything else starts ticked.
                            turn.selected = Set(parsed.proposals.filter { $0.kind != .link }.map(\.id))
                        }
                    } else {
                        update(id) { turn in
                            guard let i = turn.trace.firstIndex(where: { $0.id == call.id }) else { return }
                            turn.trace[i].detail = outcome.trace
                            turn.trace[i].finished = true
                        }
                    }
                case .done(_, let finished):
                    transcript = finished
                    // Ending on propose_actions leaves its results owed until the next question.
                    let last = finished.last
                    let calls = last?.role == .assistant ? (last?.content.compactMap(\.toolUse) ?? []) : []
                    owed = calls.filter { $0.name == AskTool.proposeActions }.map { ($0.id, id) }
                    update(id) { turn in
                        turn.phase = .answered
                        turn.seconds = self.now.timeIntervalSince(started)
                    }
                default:
                    break
                }
            }
            if turns.last?.phase == .working { update(id) { $0.phase = .failed("Claude stopped before answering.") } }
        } catch {
            update(id) { $0.phase = .failed(Self.describe(error)) }
        }
    }

    func toolbox() -> AskToolbox {
        let relay = app?.relay
        let calendar = services.calendar
        let cached = app?.plans.googleEvents ?? []
        let readsApple = calendar.access() == .full
        return AskToolbox(
            tools: AskPrompt.tools(accounts: accounts), relay: relay, people: services.people, household: household, now: now,
            events: { from, to in
                var google = cached.filter { $0.end > from && $0.start < to }
                if let relay, let fresh = try? await relay.events(from: from, to: to, refresh: false) { google = fresh.events }
                let apple = readsApple ? await calendar.events(from: from, to: to, calendarIds: nil) : []
                return google + apple
            })
    }

    // MARK: Approving

    public func toggle(_ proposalId: String, in turnId: Int) {
        guard let i = turns.firstIndex(where: { $0.id == turnId }), turns[i].run == .waiting || turns[i].isFailedRun else { return }
        if turns[i].selected.contains(proposalId) { turns[i].selected.remove(proposalId) } else { turns[i].selected.insert(proposalId) }
    }

    /// Runs the ticked steps: Google holds and replies through the relay (a reply
    /// waits 30 seconds there), reminders and family events on this phone.
    public func approve(_ turnId: Int) async {
        guard let i = turns.firstIndex(where: { $0.id == turnId }), turns[i].run == .waiting || turns[i].isFailedRun else { return }
        let turn = turns[i]
        let chosen = turn.proposals.filter { turn.selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        turns[i].run = .running
        turns[i].undoProblem = nil
        let approvedAt = now
        var executed: [Executed] = []
        var ran: Set<String> = []
        var failed: [(AskProposal, String)] = []

        var relayActions: [(AskProposal, ApprovedAction)] = []
        for p in chosen {
            switch p.kind {
            case .hold:
                guard let start = p.start, let end = p.end else { continue }
                let kind = ActionKind.createHold(account: p.account, title: p.title, start: start, end: end, notes: "Held by Hearth.")
                relayActions.append((p, ApprovedAction(kind: kind, context: .ask, approvedAt: approvedAt)))
            case .reply:
                let kind = ActionKind.reply(account: p.account, messageId: p.messageId, body: p.text, replyAll: false)
                relayActions.append(
                    (
                        p,
                        ApprovedAction(
                            kind: kind, context: .ask, approvedAt: approvedAt, notBefore: approvedAt.addingTimeInterval(Self.replyDelay))
                    ))
            default:
                break
            }
        }
        if !relayActions.isEmpty {
            do {
                guard let relay = app?.relay else { throw RelayError.notConfigured }
                let statuses = try await relay.submit(relayActions.map(\.1))
                for (p, action) in relayActions {
                    let status = statuses.first { $0.id == action.id }
                    switch status?.state {
                    case .done:
                        ran.insert(p.id)
                        if case .createHold = action.kind, let eventId = status?.result?["event_id"]?.stringValue, !eventId.isEmpty {
                            let calendarId = status?.result?["calendar_id"]?.stringValue ?? "primary"
                            executed.append(.hold(account: p.account, calendarId: calendarId, eventId: eventId))
                        } else {
                            executed.append(.sent(label: p.label))
                        }
                    case .pending:
                        ran.insert(p.id)
                        executed.append(.pending(actionId: action.id, label: p.label))
                    default:
                        failed.append((p, status?.message ?? "The relay didn't run it."))
                    }
                }
            } catch {
                failed += relayActions.map { ($0.0, Self.describe(error)) }
            }
        }

        let calendar = services.calendar
        for p in chosen {
            do {
                switch p.kind {
                case .remind:
                    guard let due = p.start else { continue }
                    if calendar.remindersAccess() != .full, await calendar.requestRemindersAccess() != .full {
                        throw CalendarWriteError.noAccess
                    }
                    let ids = try await calendar.add([ReminderDraft(title: p.title, due: due, notes: p.text.isEmpty ? nil : p.text)])
                    executed += ids.map { .reminder($0) }
                    ran.insert(p.id)
                case .event:
                    guard let start = p.start, let end = p.end else { continue }
                    if calendar.access() != .full, await calendar.requestAccess() != .full { throw CalendarWriteError.noAccess }
                    let family = household.familyCalendar.lowercased()
                    guard
                        let target = await calendar.calendars().first(where: { $0.title.lowercased() == family && $0.allowsModifications })
                    else { throw CalendarWriteError.noCalendar(household.familyCalendar) }
                    let ids = try await calendar.add(
                        [EventDraft(title: p.title, start: start, end: end, notes: "Added by Hearth.")], to: target.id)
                    executed += ids.map { .event($0) }
                    ran.insert(p.id)
                case .note, .link:
                    ran.insert(p.id)
                case .hold, .reply:
                    break
                }
            } catch {
                failed.append((p, Self.describe(error)))
            }
        }

        let done = chosen.filter { ran.contains($0.id) }
        turns[i].executed = executed
        turns[i].notes = done.filter { $0.kind == .note }
        turns[i].links = done.filter { $0.kind == .link }
        turns[i].outcome = AskOutcome.text(
            ran: done, skipped: turn.proposals.filter { !turn.selected.contains($0.id) }, failed: failed, undone: false)
        if done.isEmpty {
            turns[i].run = .failed(failed.map { "\($0.0.label): \($0.1)" }.joined(separator: " "))
        } else {
            var summary = Self.sentence(done.map(\.done))
            if !failed.isEmpty { summary += " Didn't work: " + failed.map { "\($0.0.label) (\($0.1))" }.joined(separator: "; ") + "." }
            turns[i].run = .done(summary)
        }
        if executed.contains(where: { if case .hold = $0 { true } else if case .event = $0 { true } else { false } }) {
            await app?.plans.refresh()
        }
    }

    /// Takes back what can be: reminders, events and holds, and replies still
    /// inside their 30 seconds.
    public func undo(_ turnId: Int) async {
        guard let i = turns.firstIndex(where: { $0.id == turnId }), case .done = turns[i].run else { return }
        turns[i].run = .running
        var problems: [String] = []
        var reminders: [String] = []
        var events: [String] = []
        var removals: [ApprovedAction] = []
        let relay = app?.relay
        for item in turns[i].executed {
            switch item {
            case .reminder(let id): reminders.append(id)
            case .event(let id): events.append(id)
            case .hold(let account, let calendarId, let eventId):
                removals.append(
                    ApprovedAction(
                        kind: .deleteHold(account: account, calendarId: calendarId, eventId: eventId), context: .ask, approvedAt: now))
            case .pending(let actionId, let label):
                let status = try? await relay?.cancel(id: actionId)
                if status?.state != .cancelled { problems.append("\(label): already went out.") }
            case .sent(let label):
                problems.append("\(label): already went out.")
            }
        }
        do {
            if !reminders.isEmpty { try await services.calendar.removeReminders(reminders) }
            if !events.isEmpty { try await services.calendar.removeEvents(events) }
            if !removals.isEmpty {
                guard let relay else { throw RelayError.notConfigured }
                let statuses = try await relay.submit(removals)
                if statuses.contains(where: { $0.state == .failed || $0.state == .refused }) {
                    problems.append("A hold couldn't be removed.")
                }
            }
        } catch {
            problems.append(Self.describe(error))
        }
        let ran = turns[i].proposals.filter { turns[i].selected.contains($0.id) }
        turns[i].executed = []
        turns[i].notes = []
        turns[i].links = []
        turns[i].undoProblem = problems.isEmpty ? nil : problems.joined(separator: " ")
        turns[i].outcome = AskOutcome.text(ran: ran, skipped: [], failed: [], undone: true)
        turns[i].run = .waiting
        if !removals.isEmpty || !events.isEmpty { await app?.plans.refresh() }
    }

    // MARK: Plumbing

    func update(_ id: Int, _ change: (inout Turn) -> Void) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[i])
    }

    /// "Card note drafted, Thursday reminder set."
    static func sentence(_ parts: [String]) -> String {
        let joined = parts.joined(separator: ", ")
        guard let first = joined.first else { return "" }
        return first.uppercased() + joined.dropFirst() + (joined.hasSuffix(".") ? "" : ".")
    }

    nonisolated static func describe(_ error: any Error) -> String {
        switch error {
        case let error as ClaudeError: error.description
        case let error as RelayError: error.description
        case let error as CalendarWriteError: error.description
        case let error as PeopleError: error.description
        default: String(describing: error)
        }
    }
}

extension AskModel.Turn {
    var isFailedRun: Bool {
        if case .failed = run { return true }
        return false
    }
}

/// Runs Ask's tools for one turn: mail through the relay, the rest on the phone.
struct AskToolbox: ClaudeToolbox {
    static let maxDays = 62

    let tools: [ClaudeTool]
    let relay: (any RelayAPI)?
    let people: any PeopleDirectory
    let household: Household
    let now: Date
    /// Every calendar's events overlapping a range (Google from the relay, Apple from EventKit).
    let events: @Sendable (Date, Date) async -> [AgendaEvent]

    func run(_ call: ToolUse) async -> ToolOutcome {
        let input = call.input
        let fmt = household.fmt
        switch call.name {
        case AskTool.gmailSearch:
            let search = GmailSearchRequest(
                query: input["query"]?.stringValue ?? "", account: input["account"]?.stringValue ?? "all",
                limit: min(max(input["limit"]?.intValue ?? 10, 1), GmailSearchRequest.maxLimit))
            guard let relay else { return Self.failure(RelayError.notConfigured, trace: search.query) }
            do {
                let answer = try await relay.searchMail(search)
                return AskFormat.search(answer.messages, problems: answer.problems, query: search.query, account: search.account, fmt: fmt)
            } catch {
                return Self.failure(error, trace: "account: \(search.account) · \(search.query)")
            }

        case AskTool.gmailThread:
            let account = input["account"]?.stringValue ?? ""
            let thread = input["thread_id"]?.stringValue ?? ""
            guard let relay else { return Self.failure(RelayError.notConfigured, trace: account) }
            do {
                return AskFormat.thread(try await relay.thread(account: account, threadId: thread), fmt: fmt)
            } catch {
                return Self.failure(error, trace: "\(account) · thread \(thread)")
            }

        case AskTool.agenda, AskTool.freeTime:
            guard let (from, last) = range(input) else {
                return ToolOutcome(
                    text: "Dates are YYYY-MM-DD, `to` can't come before `from`, and the range is at most \(Self.maxDays) days.",
                    isError: true, trace: "bad dates")
            }
            let end = fmt.calendar.date(byAdding: .day, value: 1, to: last) ?? last
            let agenda = Agenda(events: await events(from, end), household: household)
            guard call.name == AskTool.freeTime else { return AskFormat.agenda(agenda, from: from, through: last, fmt: fmt) }
            let part = input["part"]?.stringValue ?? "any"
            let hours: (Int, Int, Bool) = part == "work hours" ? (9, 17, true) : part == "evenings" ? (17, 22, false) : (8, 21, false)
            let days = (fmt.calendar.dateComponents([.day], from: from, to: last).day ?? 0) + 1
            let windows = agenda.freeWindows(
                from: max(from, now), days: days, dayStart: hours.0, dayEnd: hours.1,
                minimum: TimeInterval(max(input["minutes"]?.intValue ?? 30, 15) * 60), weekdaysOnly: hours.2)
            return AskFormat.freeTime(windows, from: from, through: last, part: part, fmt: fmt)

        case AskTool.peopleGet:
            let name = input["name"]?.stringValue ?? ""
            do {
                return AskFormat.people(try await people.find(name), query: name, now: now, fmt: fmt)
            } catch {
                return Self.failure(error, trace: name)
            }

        case AskTool.proposeActions:
            let parsed = AskProposal.parse(input, household: household, now: now)
            return ToolOutcome(
                text: AskProposal.receipt(parsed.proposals, problems: parsed.problems, owner: household.ownerName),
                isError: parsed.proposals.isEmpty, trace: "\(parsed.proposals.count) steps")

        default:
            return ToolOutcome(text: "There's no tool called \(call.name).", isError: true, trace: "unknown tool")
        }
    }

    /// The days a tool asked for, start of the first through the start of the last.
    func range(_ input: JSONValue) -> (Date, Date)? {
        let zone = household.zone
        guard let from = input["from"]?.stringValue.flatMap({ RFC3339.date($0 + "T00:00", zone: zone) }),
            let last = input["to"]?.stringValue.flatMap({ RFC3339.date($0 + "T00:00", zone: zone) }),
            last >= from, last.timeIntervalSince(from) <= Double(Self.maxDays) * 86400
        else { return nil }
        return (from, last)
    }

    static func failure(_ error: any Error, trace: String) -> ToolOutcome {
        ToolOutcome(text: "That didn't work: \(AskModel.describe(error))", isError: true, trace: trace + " · failed")
    }
}
