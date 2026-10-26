import Fluent
import Foundation
import HearthKit
import Logging
import RelayCore

/// Runs actions the owner approved, once each.
///
/// The phone sends a batch with an idempotency key per action. The executor
/// checks each against the policies (Ask before acting, the surprise guard),
/// stores it, and runs it now, or at `notBefore` for a scheduled send. A repeat
/// of an id it has already seen returns the stored status and runs nothing.
public actor ActionExecutor {
    public struct Settings: Sendable {
        public var household: Household
        public var rules: HouseRules

        public init(household: Household, rules: HouseRules) {
            self.household = household
            self.rules = rules
        }
    }

    private let db: any Database
    private let writer: any GoogleWriter
    private let settings: @Sendable () async -> Settings
    private let now: @Sendable () -> Date
    private let logger: Logger
    private var runningIds: Set<String> = []

    public init(
        db: any Database, writer: any GoogleWriter, settings: @escaping @Sendable () async -> Settings,
        now: @escaping @Sendable () -> Date, logger: Logger
    ) {
        self.db = db
        self.writer = writer
        self.settings = settings
        self.now = now
        self.logger = logger
    }

    /// Accepts a batch: refuses what the policies refuse, runs what's due, and
    /// returns every action's status in the order sent.
    public func submit(_ actions: [ApprovedAction]) async throws -> [ActionStatus] {
        let current = await settings()
        var out: [ActionStatus] = []
        for action in actions {
            if let existing = try await ActionModel.find(action.id, on: db) {
                out.append(try existing.status())
                continue
            }
            let model = try ActionModel(action: action, state: .pending, now: now())
            if let refusal = ApprovalPolicy.check(action, now: now()) {
                model.state = ActionState.refused.rawValue
                model.message = refusal.description
            } else if let refusal = SurpriseGuard.refusal(for: action, household: current.household, guardOn: current.rules.surpriseGuard) {
                model.state = ActionState.refused.rawValue
                model.message = refusal
            }
            try await model.create(on: db)
            if model.actionState == .pending, action.notBefore.map({ $0 <= now() }) ?? true {
                try await run(model, settings: current)
            }
            out.append(try model.status())
        }
        return out
    }

    public func statuses(ids: [String]) async throws -> [ActionStatus] {
        var out: [ActionStatus] = []
        for id in ids {
            if let model = try await ActionModel.find(id, on: db) { out.append(try model.status()) }
        }
        return out
    }

    public enum CancelError: Error, Equatable {
        case notFound
        case alreadyFinished(ActionState)
    }

    /// Takes back an action that hasn't run yet (a scheduled send).
    public func cancel(id: String) async throws -> ActionStatus {
        guard let model = try await ActionModel.find(id, on: db) else { throw CancelError.notFound }
        guard model.actionState == .pending, !runningIds.contains(id) else { throw CancelError.alreadyFinished(model.actionState) }
        model.state = ActionState.cancelled.rawValue
        model.updatedAt = now()
        try await model.update(on: db)
        return try model.status()
    }

    /// Runs scheduled actions whose time has come. Called every 30 seconds.
    @discardableResult
    public func runDue() async -> Int {
        guard let due = try? await Self.pendingAndDue(db: db, now: now()) else { return 0 }
        let current = await settings()
        var count = 0
        for model in due {
            do {
                try await run(model, settings: current)
                count += 1
            } catch {
                logger.error("scheduled action \(model.id ?? "?") failed to record: \(String(describing: error))")
            }
        }
        return count
    }

    private func run(_ model: ActionModel, settings: Settings) async throws {
        guard let id = model.id, !runningIds.contains(id) else { return }
        runningIds.insert(id)
        defer { runningIds.remove(id) }
        model.attempts += 1
        do {
            let kind = try model.kind()
            let result = try await perform(kind, settings: settings)
            model.state = ActionState.done.rawValue
            model.resultJSON = result.serialized()
            model.message = nil
            logger.info("action \(id): \(kind.summary) done")
        } catch let error as BridgeError where Self.isTransient(error) && model.attempts < Self.maxAttempts {
            // gmailkit is restarting: try again in two minutes rather than give up.
            model.notBefore = now().addingTimeInterval(120)
            model.message = "Will try again shortly: \(error)"
            logger.warning("action \(id) will retry: \(error)")
        } catch {
            model.state = ActionState.failed.rawValue
            model.message = String(describing: error)
            logger.error("action \(id) failed: \(String(describing: error))")
        }
        model.updatedAt = now()
        try await model.update(on: db)
    }

    static let maxAttempts = 5

    private func markHandled(account: String, messageId: String) async throws {
        let key = account + ":" + messageId
        if let model = try await MailTriageModel.find(key, on: db) {
            model.handledAt = now()
            try await model.update(on: db)
        } else {
            let model = MailTriageModel()
            model.id = key
            model.account = account
            model.tag = "Replied"
            model.reason = "Replied from Hearth"
            model.sorter = "claude"
            model.classifiedAt = now()
            model.handledAt = now()
            try await model.create(on: db)
        }
    }

    /// Pending with no time means it was interrupted (a restart mid-run); with a
    /// time, a scheduled send or a retry coming due. (Nonisolated: Fluent's query
    /// builder can't cross into the actor.)
    nonisolated static func pendingAndDue(db: any Database, now: Date) async throws -> [ActionModel] {
        try await ActionModel.query(on: db)
            .filter(\.$state == ActionState.pending.rawValue)
            .group(.or) { $0.filter(\.$notBefore == nil).filter(\.$notBefore <= now) }
            .all()
    }

    static func isTransient(_ error: BridgeError) -> Bool {
        switch error {
        case .notRunning, .timeout: true
        case .remote, .notAllowed, .badReply: false
        }
    }

    private func perform(_ kind: ActionKind, settings: Settings) async throws -> JSONValue {
        let cache = Cache(db: db)
        switch kind {
        case .modifyMail(let account, let ids, let change):
            let result = try await writer.modify(account: account, messageIds: ids, change: change)
            if change.archive || change.trash, let snapshot = try await cache.get(MailSnapshot.self, Cache.mailSnapshot) {
                try await cache.set(snapshot.removing(account: account, ids: Set(ids)), Cache.mailSnapshot, now: now())
            }
            return result

        case .reply(let account, let messageId, let body, let replyAll):
            let result = try await writer.reply(account: account, messageId: messageId, body: body, replyAll: replyAll)
            // Answered: it leaves the Reply queue, even though it stays in the inbox.
            try await markHandled(account: account, messageId: messageId)
            if let snapshot = try await cache.get(MailSnapshot.self, Cache.mailSnapshot) {
                try await cache.set(snapshot.removing(account: account, ids: [messageId]), Cache.mailSnapshot, now: now())
            }
            return result

        case .rsvp(let account, let calendarId, let eventId, let response):
            let row = try await writer.respond(account: account, calendarId: calendarId, eventId: eventId, response: response)
            if let snapshot = try await cache.get(EventsResponse.self, Cache.events) {
                try await cache.set(
                    CalendarSnapshot.applying(rsvp: response, account: account, eventId: eventId, to: snapshot),
                    Cache.events, now: now())
            }
            return try JSONValue(encoding: ["response": row.my_response ?? response.rawValue, "event_id": row.id ?? eventId])

        case .createHold(let account, let title, let start, let end, let notes):
            let row = try await writer.createHold(
                account: account, title: title, start: start, end: end, notes: notes,
                zone: settings.household.zone)
            if let snapshot = try await cache.get(EventsResponse.self, Cache.events),
                let event = row.agendaEvent(alias: { _ in account }, household: settings.household)
            {
                try await cache.set(CalendarSnapshot.adding(event, to: snapshot), Cache.events, now: now())
            }
            return try JSONValue(encoding: ["event_id": row.id ?? "", "calendar_id": row.calendar_id ?? "primary"])

        case .deleteHold(let account, let calendarId, let eventId):
            let result = try await writer.deleteEvent(account: account, calendarId: calendarId, eventId: eventId)
            if let snapshot = try await cache.get(EventsResponse.self, Cache.events) {
                try await cache.set(CalendarSnapshot.removing(account: account, eventId: eventId, from: snapshot), Cache.events, now: now())
            }
            return result
        }
    }
}
