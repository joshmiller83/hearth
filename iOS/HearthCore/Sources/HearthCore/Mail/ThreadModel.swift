import Foundation
import HearthKit
import Observation

/// A thread and Claude's draft reply: tones, what Claude looked at, holds for
/// the times it offers, and Send now or later (the relay keeps a scheduled send).
@MainActor
@Observable
public final class ThreadModel {
    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    public enum Drafting: Equatable, Sendable {
        case idle
        case drafting
        case ready
        case failed(String)
    }

    public enum Sending: Equatable, Sendable {
        case idle
        case sending
        case sent
        case scheduled(Date)
        case failed(String)
    }

    let services: AppServices
    weak var app: AppModel?
    public let mail: TriagedMail

    public private(set) var messages: [ThreadMessage] = []
    public private(set) var phase: Phase = .loading
    public private(set) var drafting: Drafting = .idle
    public private(set) var drafts: [DraftPrompt.Tone: DraftPrompt.Draft] = [:]
    public private(set) var tone: DraftPrompt.Tone = .drafted
    /// The draft as the owner sees and edits it.
    public var body = ""
    public var holdSlots = true
    public private(set) var sending: Sending = .idle

    public init(mail: TriagedMail, app: AppModel) {
        self.mail = mail
        self.app = app
        services = app.services
    }

    var now: Date { services.clock.now }
    var household: Household { app?.household ?? .placeholder }

    public var account: Account? { app?.health?.accounts?.first { $0.alias == mail.item.account } }

    /// "Sends from sam@rivera.example · threaded reply".
    public var fromLine: String {
        "Sends from \(account?.email ?? mail.item.account) · threaded reply"
    }

    public func load() async {
        guard let relay = app?.relay else {
            phase = .failed(RelayError.notConfigured.description)
            return
        }
        do {
            messages = try await relay.thread(account: mail.item.account, threadId: mail.item.threadId).messages
            phase = .loaded
        } catch {
            phase = .failed((error as? RelayError)?.description ?? String(describing: error))
        }
    }

    /// Drafts (or switches to) a tone. Each tone is drafted once.
    public func draft(_ tone: DraftPrompt.Tone = .drafted) async {
        self.tone = tone
        if let ready = drafts[tone] {
            body = ready.body
            drafting = .ready
            return
        }
        guard let claude = app?.claude else {
            drafting = .failed(ClaudeError.noKey.description)
            return
        }
        guard !messages.isEmpty else { return }
        drafting = .drafting
        let free = app?.plans.agenda.freeWindows(from: now, days: 7) ?? []
        let request = DraftPrompt.request(thread: messages, account: account, freeTime: free, tone: tone, household: household, now: now)
        do {
            let (draft, _) = try await claude.structured(request, as: DraftPrompt.Draft.self)
            drafts[tone] = draft
            if self.tone == tone {
                body = draft.body
                drafting = .ready
            }
        } catch {
            drafting = .failed((error as? ClaudeError)?.description ?? String(describing: error))
        }
    }

    public var currentDraft: DraftPrompt.Draft? { drafts[tone] }

    public var lookedAt: String? {
        guard let looked = currentDraft?.lookedAt, !looked.isEmpty else { return nil }
        return looked.joined(separator: " · ")
    }

    /// The windows the draft offers, as instants.
    public var offeredSlots: [DateInterval] {
        (currentDraft?.offeredSlots ?? []).compactMap { slot in
            guard let start = RFC3339.date(slot.start, zone: household.zone), let end = RFC3339.date(slot.end, zone: household.zone),
                end > start
            else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    /// "Hold these 3 slots on my calendar until Dana picks one".
    public var holdLabel: String? {
        let count = offeredSlots.count
        guard count > 0 else { return nil }
        let name = mail.item.senderName.split(separator: " ").first.map(String.init) ?? "they"
        return "Hold \(count == 1 ? "this slot" : "these \(count) slots") on my calendar until \(name) picks one"
    }

    /// Tomorrow at 8 AM, local.
    public var tomorrowMorning: Date {
        let calendar = household.fmt.calendar
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    /// Sends the reply now, or at `notBefore`, with holds for the offered times.
    public func send(at notBefore: Date? = nil) async {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let relay = app?.relay else { return }
        let replyTo = messages.last?.id ?? mail.item.id
        sending = .sending
        var actions = [
            ApprovedAction(
                kind: .reply(account: mail.item.account, messageId: replyTo, body: text, replyAll: false), context: .inbox,
                approvedAt: now, notBefore: notBefore)
        ]
        if holdSlots {
            let primary = household.primaryAccount.isEmpty ? mail.item.account : household.primaryAccount
            for slot in offeredSlots {
                actions.append(
                    ApprovedAction(
                        kind: .createHold(
                            account: primary, title: "Hold: \(mail.item.subject)", start: slot.start, end: slot.end,
                            notes: "Held for \(mail.item.senderName) until they pick a time."),
                        context: .inbox, approvedAt: now))
            }
        }
        do {
            let statuses = try await relay.submit(actions)
            guard let reply = statuses.first, reply.state == .done || reply.state == .pending else {
                sending = .failed(statuses.first?.message ?? "The relay didn't send it.")
                return
            }
            sending = notBefore.map { .scheduled($0) } ?? .sent
            app?.inbox.drop(mail)
        } catch {
            sending = .failed((error as? RelayError)?.description ?? String(describing: error))
        }
    }

    /// Archives the thread's message (after a tap; Undo is the Inbox's).
    public func archive() async {
        guard let relay = app?.relay else { return }
        let action = ApprovedAction(
            kind: .modifyMail(account: mail.item.account, messageIds: [mail.item.id], change: .archive), context: .inbox, approvedAt: now)
        if let status = try? await relay.submit([action]).first, status.state == .done || status.state == .pending {
            app?.inbox.drop(mail)
        }
    }
}
