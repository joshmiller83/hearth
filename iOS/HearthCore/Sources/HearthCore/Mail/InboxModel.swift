import Foundation
import HearthKit
import Observation

/// The Inbox: every account's mail in four queues, sorted by the relay. Nothing
/// moves until the owner approves a queue; then it goes in one batch per
/// account after a 10-second undo window. Trash is as far as anything goes.
/// Any message can be left out of its queue: it stays in the inbox, off every
/// queue, until it's put back.
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

    /// A batch the owner approved, waiting out its undo window or being sent.
    /// Several can be on their way at once; the queue's button stays.
    public struct Approval: Identifiable, Equatable, Sendable {
        public enum State: Equatable, Sendable {
            case waiting(until: Date)
            case sending
            case done(String)
            case failed(String)
        }

        public let id: Int
        /// What happens to them: archived, trashed or filed.
        public var queue: MailQueue
        public var items: [TriagedMail]
        public var state: State
        public var count: Int { items.count }
    }

    let services: AppServices
    weak var app: AppModel?

    /// The relay's sort, as it last came.
    private(set) var sorted: MailSnapshot?
    public private(set) var phase: Phase = .idle
    public private(set) var approvals: [Approval] = []
    private var nextApproval = 1
    /// Messages the owner left out (`TriagedMail.id`s): they stay in the inbox, off every queue.
    public private(set) var leftOut: Set<String>
    /// Left out since this queue was opened: they stay in place, dimmed, so the rows don't shift under a finger.
    public private(set) var justLeftOut: Set<String> = []
    private var upload: Task<Void, Never>?
    /// Nil shows every account.
    public var account: String? { didSet { justLeftOut = [] } }
    public var queue: MailQueue = .reply { didSet { justLeftOut = [] } }

    init(services: AppServices) {
        self.services = services
        sorted = services.database.load(MailSnapshot.self, key: StoreKey.mail)
        leftOut = Set(services.database.load([String].self, key: StoreKey.leftOut) ?? [])
    }

    /// The inbox as every screen sees it: left-out mail kept, approved batches already gone.
    public var snapshot: MailSnapshot? {
        guard let sorted else { return nil }
        var out = sorted.leavingOut(leftOut)
        let moving = self.moving
        if !moving.isEmpty { out.items.removeAll { moving.contains($0.id) } }
        return out
    }

    /// In a batch that's waiting out its undo window or being sent.
    var moving: Set<String> {
        Set(approvals.filter { !$0.isFinished }.flatMap { $0.items.map(\.id) })
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
            sorted = fresh
            justLeftOut = []
            try? services.database.save(fresh, key: StoreKey.mail, now: now)
            // Forget what left the inbox some other way, except where an account couldn't be read.
            let present = Set(fresh.items.map(\.id))
            let unread = Set(fresh.problems.map(\.source))
            let keep = leftOut.filter { id in present.contains(id) || unread.contains(String(id.prefix { $0 != ":" })) }
            if keep != leftOut {
                leftOut = keep
                saveLeftOut()
            }
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

    /// The selected queue's rows, newest first. A row left out just now stays in place, dimmed.
    public var rows: [Row] {
        Self.rows(queueItems.filter { !leftOut.contains($0.id) || justLeftOut.contains($0.id) })
    }

    /// Rows left out before, folded under "N left out" at the end of the queue.
    public var leftOutRows: [Row] {
        Self.rows(queueItems.filter { leftOut.contains($0.id) && !justLeftOut.contains($0.id) })
    }

    /// How many in the selected queue are left out.
    public var leftOutCount: Int { queueItems.filter { leftOut.contains($0.id) }.count }

    public func isLeftOut(_ row: Row) -> Bool { row.items.allSatisfy { leftOut.contains($0.id) } }

    /// Everything the relay put in the selected queue, apart from batches on their way.
    var queueItems: [TriagedMail] {
        guard let sorted else { return [] }
        let moving = self.moving
        return sorted.items(in: queue, account: account).filter { !moving.contains($0.id) }
    }

    static func rows(_ items: [TriagedMail]) -> [Row] {
        var rows: [Row] = []
        var bundles: [String: Int] = [:]
        for item in items {
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
        case .jobHunt: return count == 0 ? "Nothing to file" : "File \(count)"
        case .archive: return count == 0 ? "Nothing to archive" : "Archive \(count)"
        case .delete: return count == 0 ? "Nothing to trash" : "Move \(count) to Trash"
        }
    }

    public var actionNote: String {
        let note: String
        switch queue {
        case .reply: note = "Each reply sends only after you tap Send on it."
        case .jobHunt: note = "Labels each one job hunt and files it. Your routines scan picks them up."
        case .archive: note = "One batch per account. Undo for 10 seconds."
        case .delete: note = "Trash, not permanent. Gmail empties it after 30 days."
        }
        let left = leftOutCount
        return left == 0 ? note : note + " \(left) left out stay\(left == 1 ? "s" : "") in your inbox."
    }

    public var sweepLine: String {
        guard let snapshot else { return "Hearth sorts every inbox every 15 minutes. Connect the relay in Sources." }
        let fmt = household.fmt
        return
            "Sorted \(snapshot.newCount) new message\(snapshot.newCount == 1 ? "" : "s") by \(fmt.time(snapshot.generatedAt)). Nothing moves until you approve a queue."
    }

    // MARK: Leaving mail out

    /// Leaves a row out of its queue (it stays in the inbox), or puts it back.
    public func toggle(_ row: Row) {
        let ids = Set(row.items.map(\.id))
        if ids.isSubset(of: leftOut) {
            leftOut.subtract(ids)
            justLeftOut.subtract(ids)
        } else {
            leftOut.formUnion(ids)
            justLeftOut.formUnion(ids)
        }
        saveLeftOut()
    }

    /// Leaves one message out from elsewhere ("Not for me" on Today).
    public func leaveOut(_ id: String) {
        guard !leftOut.contains(id) else { return }
        leftOut.insert(id)
        saveLeftOut()
    }

    func saveLeftOut() {
        try? services.database.save(leftOut.sorted(), key: StoreKey.leftOut, now: now)
        app?.plans.publishWidgets()
        // The brief should skip them too; one upload for a run of taps.
        upload?.cancel()
        upload = Task { [services, weak app] in
            await services.wait(2)
            guard !Task.isCancelled else { return }
            await app?.uploadContext()
        }
    }

    // MARK: Approving a queue

    /// Starts the undo window for what's still checked in the selected queue (not Reply: replies go one at a time).
    public func approve() {
        guard queue != .reply else { return }
        start(queue, snapshot?.items(in: queue, account: account) ?? [])
    }

    /// Archives what was left out of the selected queue: a "Reply" that isn't one needn't sit in the inbox.
    public func archiveLeftOut() {
        guard queue != .archive else { return }
        start(.archive, queueItems.filter { leftOut.contains($0.id) })
    }

    func start(_ queue: MailQueue, _ items: [TriagedMail]) {
        guard !items.isEmpty else { return }
        approvals.removeAll { if case .done = $0.state { true } else { false } }
        let id = nextApproval
        nextApproval += 1
        approvals.append(Approval(id: id, queue: queue, items: items, state: .waiting(until: now.addingTimeInterval(Self.undoSeconds))))
        Task { [services] in
            await services.wait(Self.undoSeconds)
            await self.sendIfStillWaiting(id)
        }
    }

    public func undo(_ id: Approval.ID) {
        guard let index = approvals.firstIndex(where: { $0.id == id }), case .waiting = approvals[index].state else { return }
        approvals.remove(at: index)
    }

    public func dismiss(_ id: Approval.ID) {
        approvals.removeAll { $0.id == id && $0.isFinished }
    }

    func sendIfStillWaiting(_ id: Approval.ID) async {
        guard let pending = approvals.first(where: { $0.id == id }), case .waiting = pending.state else { return }
        guard let relay = app?.relay else {
            update(id, .failed(RelayError.notConfigured.description))
            return
        }
        update(id, .sending)
        let byAccount = Dictionary(grouping: pending.items, by: \.item.account)
        let actions = byAccount.sorted { $0.key < $1.key }.map { account, items in
            ApprovedAction(
                kind: .modifyMail(account: account, messageIds: items.map(\.item.id), change: change(for: pending.queue, account: account)),
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
                    forget(account: account, ids: Set(ids))
                } else {
                    failures.append("\(account): \(status.message ?? status.state.rawValue)")
                }
            }
            update(id, failures.isEmpty ? .done(doneLine(pending.queue, filed)) : .failed(failures.joined(separator: "; ")))
        } catch {
            update(id, .failed((error as? RelayError)?.description ?? String(describing: error)))
        }
        app?.plans.publishWidgets()
    }

    func update(_ id: Approval.ID, _ state: Approval.State) {
        guard let index = approvals.firstIndex(where: { $0.id == id }) else { return }
        approvals[index].state = state
    }

    /// "Archiving 34 in 7 s", "Archiving 34…".
    public func doing(_ approval: Approval) -> String {
        let verb: String
        switch approval.queue {
        case .reply: verb = "Marking"
        case .jobHunt: verb = "Filing"
        case .archive: verb = "Archiving"
        case .delete: verb = "Trashing"
        }
        switch approval.state {
        case .waiting(let until): return "\(verb) \(approval.count) in \(max(1, Int(until.timeIntervalSince(now).rounded(.up)))) s"
        case .sending: return "\(verb) \(approval.count)…"
        case .done(let line), .failed(let line): return line
        }
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
        sorted = sorted?.removing(account: account, ids: ids)
        if let sorted { try? services.database.save(sorted, key: StoreKey.mail, now: now) }
        let gone = Set(ids.map { account + ":" + $0 })
        if !leftOut.isDisjoint(with: gone) {
            leftOut.subtract(gone)
            try? services.database.save(leftOut.sorted(), key: StoreKey.leftOut, now: now)
        }
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
    public static let leftOut = "inbox.leftOut"
}
