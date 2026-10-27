import Foundation
import HearthKit
import Observation

/// Signals: what's worth a glance from GitHub, Planning Center, Facebook,
/// carriers and family (worked out here from the inbox sweep), plus the
/// weather the relay watches. Bundles turn the rest down to a line each.
@MainActor
@Observable
public final class SignalsModel {
    let services: AppServices
    weak var app: AppModel?

    public private(set) var relaySignals: RelaySignals?
    public private(set) var problem: String?
    public var filter: Signal.Category?
    public var showLower = false
    /// What's been done from here, by signal: "Reminder set for 5:00 PM".
    public private(set) var done: [String: String] = [:]
    /// The last bundle cleared: "Marked 2 read."
    public private(set) var cleared: String?
    public private(set) var working: Set<String> = []

    init(services: AppServices) {
        self.services = services
        relaySignals = services.database.load(RelaySignals.self, key: StoreKey.signals)
    }

    var now: Date { services.clock.now }
    var household: Household { app?.household ?? .placeholder }

    public func refresh() async {
        guard let relay = app?.relay else { return }
        do {
            let fresh = try await relay.signals()
            relaySignals = fresh
            problem = fresh.problems.first?.message
            try? services.database.save(fresh, key: StoreKey.signals, now: now)
        } catch {
            problem = (error as? RelayError)?.description ?? String(describing: error)
        }
    }

    var fromMail: (signals: [Signal], bundles: [SignalBundle]) {
        guard let mail = app?.inbox.snapshot else { return ([], []) }
        return Signals.fromMail(mail, household: household, now: now)
    }

    /// Every signal, most pressing first.
    public var all: [Signal] { Signals.sorted(fromMail.signals + (relaySignals?.signals ?? [])) }

    /// The chips: the categories that have something in them.
    public var categories: [Signal.Category] {
        let present = Set(all.map(\.category))
        return Signal.Category.allCases.filter(present.contains)
    }

    func shown(_ signal: Signal) -> Bool { filter == nil || signal.category == filter }

    /// "Worth your attention".
    public var worth: [Signal] { all.filter { $0.priority >= 1 && shown($0) } }
    /// "N more, lower priority".
    public var lower: [Signal] { all.filter { $0.priority == 0 && shown($0) } }
    public var bundles: [SignalBundle] { fromMail.bundles }
    public var quietCount: Int { bundles.reduce(0) { $0 + $1.count } }
    /// Pushed-grade signals, which Today and the widgets count.
    public var pressing: [Signal] { all.filter { $0.priority >= 2 } }
    /// The bell's number.
    public var badge: Int { all.filter { $0.priority >= 1 }.count }

    public var summary: String {
        Signals.summary(
            mail: app?.inbox.snapshot, worth: badge, household: household, quiet: app?.rules.quietHours ?? QuietHours(), now: now)
    }

    /// "now", "45 min", "2 h", "Sun", "Oct 3"; a time for what's still ahead.
    public func age(_ date: Date) -> String {
        let fmt = household.fmt
        if date > now.addingTimeInterval(60) { return fmt.time(date) }
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 24 * 60 { return "\(minutes / 60) h" }
        if minutes < 6 * 24 * 60 { return fmt.weekday(date) }
        return Fmt.monthsShort[fmt.calendar.component(.month, from: date) - 1] + " " + String(fmt.dayOfMonth(date))
    }

    // MARK: Doing things

    /// A reminder on this phone, from a signal's button.
    public func remind(_ signal: Signal, title: String, at date: Date) async {
        working.insert(signal.id)
        defer { working.remove(signal.id) }
        let calendar = services.calendar
        do {
            if calendar.remindersAccess() != .full, await calendar.requestRemindersAccess() != .full { throw CalendarWriteError.noAccess }
            _ = try await calendar.add([ReminderDraft(title: title, due: date)])
            done[signal.id] = "Reminder set for \(household.fmt.time(date))"
        } catch {
            done[signal.id] = (error as? CalendarWriteError)?.description ?? "The reminder didn't save."
        }
    }

    /// Archives the emails behind a bundle, marked read, one batch per account.
    public func markRead(_ bundle: SignalBundle, mail: [Signal.MailRef]) async {
        guard let relay = app?.relay, !mail.isEmpty else { return }
        working.insert(bundle.id)
        defer { working.remove(bundle.id) }
        let actions = Dictionary(grouping: mail, by: \.account).sorted { $0.key < $1.key }.map { account, refs in
            ApprovedAction(
                kind: .modifyMail(account: account, messageIds: refs.map(\.messageId), change: .archive), context: .inbox, approvedAt: now)
        }
        do {
            let statuses = try await relay.submit(actions)
            var count = 0
            for (action, status) in zip(actions, statuses) where status.state == .done || status.state == .pending {
                guard case .modifyMail(let account, let ids, _) = action.kind else { continue }
                app?.inbox.forget(account: account, ids: Set(ids))
                count += ids.count
            }
            cleared =
                count == mail.count ? "\(bundle.title): marked \(count) read." : "\(bundle.title): marked \(count) of \(mail.count) read."
        } catch {
            cleared = "\(bundle.title): \((error as? RelayError)?.description ?? String(describing: error))"
        }
    }

    /// The email behind a signal, to read it in Hearth.
    public func mail(_ ref: Signal.MailRef) -> TriagedMail? {
        app?.inbox.snapshot?.items.first { $0.item.account == ref.account && $0.item.id == ref.messageId }
    }
}

extension StoreKey {
    public static let signals = "relay.signals"
}
