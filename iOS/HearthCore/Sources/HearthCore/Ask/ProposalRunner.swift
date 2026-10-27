import Foundation
import HearthKit

/// Runs steps the owner approved, from Ask or from People: Google holds and
/// replies through the relay (a reply waits 30 seconds there so Undo can stop
/// it), reminders and family events on this phone, notes and links kept for
/// Copy and Open. Undo takes back what it still can.
@MainActor
struct ProposalRunner {
    /// What a step left behind, for Undo.
    enum Receipt: Equatable, Sendable {
        case reminder(String)
        case event(String)
        case hold(account: String, calendarId: String, eventId: String)
        /// Waiting at the relay (a reply's 30 seconds): cancelling stops it.
        case pending(actionId: String, label: String)
        /// Done at the relay and not reversible.
        case sent(label: String)
    }

    struct Outcome {
        var ran: [AskProposal] = []
        var failed: [(AskProposal, String)] = []
        var receipts: [Receipt] = []
    }

    let services: AppServices
    let relay: (any RelayAPI)?
    let household: Household
    var context: ActionContext = .ask
    var replyDelay: TimeInterval = 30

    func run(_ chosen: [AskProposal], now: Date) async -> Outcome {
        var outcome = Outcome()
        var ran: Set<String> = []

        var relayActions: [(AskProposal, ApprovedAction)] = []
        for p in chosen {
            switch p.kind {
            case .hold:
                guard let start = p.start, let end = p.end else { continue }
                let notes = context == .surprise ? SurpriseMarker.notes("Planned in Hearth.") : "Held by Hearth."
                let kind = ActionKind.createHold(account: p.account, title: p.title, start: start, end: end, notes: notes)
                relayActions.append((p, ApprovedAction(kind: kind, context: context, approvedAt: now)))
            case .reply:
                let kind = ActionKind.reply(account: p.account, messageId: p.messageId, body: p.text, replyAll: false)
                relayActions.append(
                    (p, ApprovedAction(kind: kind, context: context, approvedAt: now, notBefore: now.addingTimeInterval(replyDelay))))
            default:
                break
            }
        }
        if !relayActions.isEmpty {
            do {
                guard let relay else { throw RelayError.notConfigured }
                let statuses = try await relay.submit(relayActions.map(\.1))
                for (p, action) in relayActions {
                    let status = statuses.first { $0.id == action.id }
                    switch status?.state {
                    case .done:
                        ran.insert(p.id)
                        if case .createHold = action.kind, let eventId = status?.result?["event_id"]?.stringValue, !eventId.isEmpty {
                            let calendarId = status?.result?["calendar_id"]?.stringValue ?? "primary"
                            outcome.receipts.append(.hold(account: p.account, calendarId: calendarId, eventId: eventId))
                        } else {
                            outcome.receipts.append(.sent(label: p.label))
                        }
                    case .pending:
                        ran.insert(p.id)
                        outcome.receipts.append(.pending(actionId: action.id, label: p.label))
                    default:
                        outcome.failed.append((p, status?.message ?? "The relay didn't run it."))
                    }
                }
            } catch {
                outcome.failed += relayActions.map { ($0.0, AskModel.describe(error)) }
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
                    outcome.receipts += ids.map { .reminder($0) }
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
                    outcome.receipts += ids.map { .event($0) }
                    ran.insert(p.id)
                case .note, .link:
                    ran.insert(p.id)
                case .hold, .reply:
                    break
                }
            } catch {
                outcome.failed.append((p, AskModel.describe(error)))
            }
        }
        outcome.ran = chosen.filter { ran.contains($0.id) }
        return outcome
    }

    /// Takes back what can be; returns what couldn't be.
    func undo(_ receipts: [Receipt], now: Date) async -> [String] {
        var problems: [String] = []
        var reminders: [String] = []
        var events: [String] = []
        var removals: [ApprovedAction] = []
        for receipt in receipts {
            switch receipt {
            case .reminder(let id): reminders.append(id)
            case .event(let id): events.append(id)
            case .hold(let account, let calendarId, let eventId):
                removals.append(
                    ApprovedAction(
                        kind: .deleteHold(account: account, calendarId: calendarId, eventId: eventId), context: context, approvedAt: now))
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
            problems.append(AskModel.describe(error))
        }
        return problems
    }

    /// "Card note drafted, Thursday reminder set."
    static func sentence(_ parts: [String]) -> String {
        let joined = parts.joined(separator: ", ")
        guard let first = joined.first else { return "" }
        return first.uppercased() + joined.dropFirst() + (joined.hasSuffix(".") ? "" : ".")
    }

    /// Whether any step changed a calendar (so Plans should refresh).
    static func touchesCalendars(_ receipts: [Receipt]) -> Bool {
        receipts.contains { receipt in
            switch receipt {
            case .hold, .event: true
            case .reminder, .pending, .sent: false
            }
        }
    }
}
