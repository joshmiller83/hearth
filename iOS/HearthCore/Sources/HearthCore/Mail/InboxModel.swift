import Foundation
import HearthKit
import Observation

/// The Inbox: every account's mail in four queues, sorted by the relay. Nothing
/// moves until the owner approves a queue; then it goes in one batch per
/// account after a 10-second undo window. Trash is as far as anything goes.
@MainActor
@Observable
public final class InboxModel {
    public static let undoSeconds: TimeInterval = 10

    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// One line in a queue: a message, or a bundle of them ("GitHub · 23 updates").
    public struct Row: Identifiable, Equatable, Sendable {
        public var id: String
        public var items: [TriagedMail]
        public var isBundle: Bool { items.count > 1 }
        public var first: TriagedMail { items[0] }
    }

    /// A queue the owner approved, waiting out its undo window or being sent.
    public struct Approval: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            case waiting(until: Date)
            case sending
            case done(String)
            case failed(String)
        }

        public var queue: MailQueue
        public var account: String?
        public var count: Int
        public var state: State
    }

    let services: AppServices
    weak var app: AppModel?

    public private(set) var snapshot: MailSnapshot?
    public private(set) var phase: Phase = .idle
    public private(set) var approval: Approval?
    /// Nil shows every account.
    public var account: String?
    public var queue: MailQueue = .reply

    init(services: AppServices) {
        self.services = services
        snapshot = services.database.load(MailSnapshot.self, key: StoreKey.mail)
    }

    var now: Date { services.clock.now }
    var household: Household { app?.household ?? .placeholder }

    // MARK: Loading

    public func refresh(force: Bool = false) async {
        guard let relay = app?.relay else {
            phase = .failed(RelayError.notConfigured.description)
            return
        }
        phase = .loading
        do {
            let fresh = try await relay.mailSnapshot(refresh: force)
            snapshot = fresh
            try? services.database.save(fresh, key: StoreKey.mail, now: now)
            phase = .loaded
        } catch {
            phase = .failed((error as? RelayError)?.description ?? String(describing: error))
        }
    }

    // MARK: What the screen shows

    /// Accounts in the household's order (owner's first), then any others.
    public var accounts: [String] {
        let present = Set(snapshot?.accounts ?? [])
        let ordered = (household.ownerAccounts + household.partnerAccounts).filter(present.contains)
        return ordered + present.subtracting(ordered).sorted()
    }

    public func count(_ queue: MailQueue) -> Int {
        snapshot?.items(in: queue, account: account).count ?? 0
    }

    public var rows: [Row] {
        guard let snapshot else { return [] }
        var rows: [Row] = []
        var bundles: [String: Int] = [:]
        for item in snapshot.items(in: queue, account: account) {
            if let bundle = item.bundle {
                let key = item.item.account + ":" + bundle
                if let index = bundles[key] {
                    rows[index].items.append(item)
                    continue
                }
                bundles[key] = rows.count
            }
            rows.append(Row(id: item.id, items: [item]))
        }
        return rows
    }

    /// "Kept in your inbox: 33 security alerts, 2 GitHub reviews. Those never auto-archive."
    public var keptNote: String? {
        guard let kept = snapshot?.kept(account: account), !kept.isEmpty else { return nil }
        // Most first; ties by name, so the line doesn't reshuffle between redraws.
        let groups = Dictionary(grouping: kept, by: \.tag).sorted { ($1.value.count, $0.key) < ($0.value.count, $1.key) }
        let parts = groups.map { tag, items in "\(items.count) \(tag.lowercased())" }
        return "Kept in your inbox: " + parts.joined(separator: ", ") + ". Those never move without you."
    }

    public var headline: String {
        let items = snapshot?.items(in: queue, account: account) ?? []
        switch queue {
        case .reply:
            return "Reply · \(items.count)"
        case .jobHunt:
            let applications = items.filter { $0.tag == "Application" }.count
            return applications > 0 ? "Job hunt · \(applications) about applications" : "Job hunt · \(items.count)"
        case .archive:
            let accounts = Set(items.map(\.item.account)).count
            return "Archive · \(items.count) across \(accounts) account\(accounts == 1 ? "" : "s")"
        case .delete:
            return "Delete · promos unopened for 90 days"
        }
    }

    public var actionLabel: String {
        let count = self.count(queue)
        switch queue {
        case .reply: return count == 0 ? "Nothing to answer" : "Open the first"
        case .jobHunt: return "File \(count)"
        case .archive: return "Archive \(count)"
        case .delete: return "Move \(count) to Trash"
        }
    }

    public var actionNote: String {
        switch queue {
        case .reply: return "Each reply sends only after you tap Send on it."
        case .jobHunt: return "Labels each one job hunt and files it. Your routines scan picks them up."
        case .archive: return "One batch per account. Undo for 10 seconds."
        case .delete: return "Trash, not permanent. Gmail empties it after 30 days."
        }
    }

    public var sweepLine: String {
        guard let snapshot else { return "Hearth sorts every inbox every 15 minutes. Connect the relay in Sources." }
        let fmt = household.fmt
        return
            "Sorted \(snapshot.newCount) new message\(snapshot.newCount == 1 ? "" : "s") by \(fmt.time(snapshot.generatedAt)). Nothing moves until you approve a queue."
    }

    // MARK: Approving a queue

    /// Starts the undo window for the selected queue (not Reply: replies go one at a time).
    public func approve() {
        guard queue != .reply, approval == nil || approval?.isFinished == true else { return }
        let count = self.count(queue)
        guard count > 0 else { return }
        let until = now.addingTimeInterval(Self.undoSeconds)
        approval = Approval(queue: queue, account: account, count: count, state: .waiting(until: until))
        let queue = queue
        let account = account
        Task { [services] in
            await services.wait(Self.undoSeconds)
            await self.sendIfStillWaiting(queue, account)
        }
    }

    public func undo() {
        guard case .waiting = approval?.state else { return }
        approval = nil
    }

    public func dismissApproval() {
        if approval?.isFinished == true { approval = nil }
    }

    func sendIfStillWaiting(_ queue: MailQueue, _ account: String?) async {
        guard let pending = approval, pending.queue == queue, pending.account == account, case .waiting = pending.state else { return }
        guard let relay = app?.relay, let snapshot else {
            approval?.state = .failed(RelayError.notConfigured.description)
            return
        }
        approval?.state = .sending
        let byAccount = Dictionary(grouping: snapshot.items(in: queue, account: account), by: \.item.account)
        let actions = byAccount.sorted { $0.key < $1.key }.map { account, items in
            ApprovedAction(
                kind: .modifyMail(account: account, messageIds: items.map(\.item.id), change: change(for: queue, account: account)),
                context: .inbox, approvedAt: now)
        }
        do {
            let statuses = try await relay.submit(actions)
            var filed = 0
            var failures: [String] = []
            for (action, status) in zip(actions, statuses) {
                guard case .modifyMail(let account, let ids, _) = action.kind else { continue }
                if status.state == .done || status.state == .pending {
                    filed += ids.count
                    self.snapshot = self.snapshot?.removing(account: account, ids: Set(ids))
                } else {
                    failures.append("\(account): \(status.message ?? status.state.rawValue)")
                }
            }
            if let current = self.snapshot { try? services.database.save(current, key: StoreKey.mail, now: now) }
            approval?.state = failures.isEmpty ? .done(doneLine(queue, filed)) : .failed(failures.joined(separator: "; "))
        } catch {
            approval?.state = .failed((error as? RelayError)?.description ?? String(describing: error))
        }
        app?.plans.publishWidgets()
    }

    func change(for queue: MailQueue, account: String) -> MailChange {
        switch queue {
        case .reply: return .markRead
        case .archive: return .archive
        case .delete: return .trash
        case .jobHunt:
            // File it: the account's own "job hunt" label where it has one, then out of the inbox.
            let label = snapshot?.jobHuntLabels[account] != nil ? ["job hunt"] : []
            return MailChange(archive: true, markRead: true, addLabels: label)
        }
    }

    func doneLine(_ queue: MailQueue, _ count: Int) -> String {
        switch queue {
        case .reply: return "Marked \(count) read"
        case .jobHunt: return "Filed \(count)"
        case .archive: return "Archived \(count)"
        case .delete: return "Moved \(count) to Trash"
        }
    }

    /// Takes one message out of the snapshot (after it's been archived or answered from its thread).
    func drop(_ mail: TriagedMail) {
        forget(account: mail.item.account, ids: [mail.item.id])
    }

    /// Takes messages filed from elsewhere (Signals' Mark read) out of the snapshot.
    func forget(account: String, ids: Set<String>) {
        snapshot = snapshot?.removing(account: account, ids: ids)
        if let snapshot { try? services.database.save(snapshot, key: StoreKey.mail, now: now) }
    }

    /// The row's time: "8:12 AM" today, "Sun" this week, "Oct 3" before that.
    public func time(_ date: Date) -> String {
        let fmt = household.fmt
        if fmt.calendar.isDate(date, inSameDayAs: now) { return fmt.time(date) }
        if now.timeIntervalSince(date) < 6 * 86400 { return fmt.weekday(date) }
        return Fmt.monthsShort[fmt.calendar.component(.month, from: date) - 1] + " " + String(fmt.dayOfMonth(date))
    }
}

extension InboxModel.Approval {
    var isFinished: Bool {
        switch state {
        case .done, .failed: true
        case .waiting, .sending: false
        }
    }
}

extension StoreKey {
    public static let mail = "relay.mail"
}
