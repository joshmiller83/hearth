import Fluent
import Foundation
import HearthKit
import Logging
import RelayCore

/// When a job runs.
public enum JobSchedule: Sendable, Equatable {
    /// Every so many seconds.
    case every(TimeInterval)
    /// Once a day at a local time.
    case daily(hour: Int, minute: Int)
    /// Once a week (1 = Sunday … 7 = Saturday) at a local time.
    case weekly(weekday: Int, hour: Int, minute: Int)

    /// The most recent time this schedule fired at or before `now` (nil for `every`).
    func lastSlot(before now: Date, zone: TimeZone) -> Date? {
        let calendar = Fmt(zone: zone).calendar
        switch self {
        case .every:
            return nil
        case .daily(let hour, let minute):
            guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
            return today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today)
        case .weekly(let weekday, let hour, let minute):
            guard var day = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
            for _ in 0..<8 {
                if calendar.component(.weekday, from: day) == weekday, day <= now { return day }
                guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { return nil }
                day = previous
            }
            return nil
        }
    }

    /// Due when it has never run, its interval has passed, or a slot came since it last ran.
    public func isDue(lastRun: Date?, now: Date, zone: TimeZone) -> Bool {
        switch self {
        case .every(let interval):
            guard let lastRun else { return true }
            return now.timeIntervalSince(lastRun) >= interval - 1
        case .daily, .weekly:
            guard let slot = lastSlot(before: now, zone: zone) else { return false }
            // A slot more than 12 hours gone isn't worth catching up (the Mac was off overnight).
            guard now.timeIntervalSince(slot) < 12 * 3600 else { return false }
            guard let lastRun else { return true }
            return lastRun < slot
        }
    }

    /// When it will next be due, for the Sources screen.
    public func nextRun(lastRun: Date?, now: Date, zone: TimeZone) -> Date? {
        let calendar = Fmt(zone: zone).calendar
        switch self {
        case .every(let interval):
            return (lastRun ?? now).addingTimeInterval(interval)
        case .daily(let hour, let minute):
            guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
            return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
        case .weekly:
            guard let last = lastSlot(before: now, zone: zone) else { return nil }
            return calendar.date(byAdding: .day, value: 7, to: last)
        }
    }
}

/// What a job gets to work with: the database, read-only Google, the household,
/// the clock. No way to write to mail or calendars.
public struct JobContext: Sendable {
    public var db: any Database
    public var google: any GoogleReader
    public var household: Household
    public var now: @Sendable () -> Date
    public var logger: Logger
    /// The relay's own Claude client, when it has a key.
    public var claude: ClaudeClient?
    /// Plain HTTPS, for public sources like the weather service.
    public var http: (any HTTPTransport)?
    /// Texts and bridged chats, where the bridges job keeps what it reads.
    public var chats: ChatStore?
    /// The Mac's Matrix homeserver, when it runs the bridges.
    public var matrix: MatrixAccess?

    public init(
        db: any Database, google: any GoogleReader, household: Household, now: @escaping @Sendable () -> Date,
        logger: Logger, claude: ClaudeClient? = nil, http: (any HTTPTransport)? = nil, chats: ChatStore? = nil,
        matrix: MatrixAccess? = nil
    ) {
        self.db = db
        self.google = google
        self.household = household
        self.now = now
        self.logger = logger
        self.claude = claude
        self.http = http
        self.chats = chats
        self.matrix = matrix
    }

    public var cache: Cache { Cache(db: db) }
}

public protocol RelayJob: Sendable {
    var name: String { get }
    var schedule: JobSchedule { get }
    func run(_ context: JobContext) async throws
}

/// Runs whichever jobs are due, one at a time, and records each run.
public actor JobRunner {
    public nonisolated let jobs: [any RelayJob]
    private var running = false

    public init(jobs: [any RelayJob]) {
        self.jobs = jobs
    }

    /// Runs every job that's due now. Returns the names it ran.
    @discardableResult
    public func tick(_ context: JobContext) async -> [String] {
        guard !running else { return [] }
        running = true
        defer { running = false }
        var ran: [String] = []
        for job in jobs {
            let record = (try? await JobRunModel.find(job.name, on: context.db)) ?? nil
            guard job.schedule.isDue(lastRun: record?.lastRun, now: context.now(), zone: context.household.zone) else { continue }
            await run(job, context)
            ran.append(job.name)
        }
        return ran
    }

    /// Runs one job now, whatever its schedule (`Run run-job <name>`, "refresh").
    public func run(named name: String, _ context: JobContext) async -> Bool {
        guard let job = jobs.first(where: { $0.name == name }) else { return false }
        await run(job, context)
        return true
    }

    private func run(_ job: any RelayJob, _ context: JobContext) async {
        let started = context.now()
        var error: (any Error)?
        do {
            try await job.run(context)
        } catch let e {
            error = e
            context.logger.error("job \(job.name) failed: \(String(describing: e))")
        }
        do {
            let record = try await JobRunModel.find(job.name, on: context.db) ?? JobRunModel(name: job.name)
            record.lastRun = started
            if let error {
                record.lastError = String(String(describing: error).prefix(500))
            } else {
                record.lastSuccess = context.now()
                record.lastError = nil
            }
            try await record.save(on: context.db)
        } catch {
            context.logger.error("couldn't record job \(job.name): \(String(describing: error))")
        }
    }

    /// Each job's last run and next run, for `/v1/health`.
    public func statuses(_ context: JobContext) async -> [JobStatus] {
        var out: [JobStatus] = []
        for job in jobs {
            let record = (try? await JobRunModel.find(job.name, on: context.db)) ?? nil
            out.append(
                JobStatus(
                    name: job.name,
                    lastRun: record?.lastRun,
                    lastSuccess: record?.lastSuccess,
                    lastError: record?.lastError,
                    nextRun: job.schedule.nextRun(lastRun: record?.lastRun, now: context.now(), zone: context.household.zone)
                ))
        }
        return out
    }
}
