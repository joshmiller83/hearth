import Foundation
import HearthKit
import RelayCore

/// Every 15 minutes: every calendar on every account, a week back and two months
/// ahead, cached for the phone. No AI.
public struct CalendarCacheJob: RelayJob {
    public static let jobName = "calendar"
    public var name: String { Self.jobName }
    public var schedule: JobSchedule { .every(15 * 60) }

    public init() {}

    public func run(_ context: JobContext) async throws {
        _ = try await Self.refresh(context)
    }

    /// Sweeps Google and replaces the cache. Also used by `?refresh=1`.
    public static func refresh(_ context: JobContext) async throws -> EventsResponse {
        let google = context.google
        let calendars = try await google.calendars()
        let rows = try await google.events(daysBack: 7, daysAhead: 60, limit: 2000, zone: context.household.timeZone)
        let snapshot = CalendarSnapshot.build(
            rows: rows, calendars: calendars, aliases: await google.aliases(),
            household: context.household, now: context.now()
        )
        try await context.cache.set(snapshot, Cache.events, now: context.now())
        context.logger.info(
            "calendar: \(snapshot.events.count) events from \(snapshot.calendars.count) calendars, \(snapshot.problems.count) problems")
        return snapshot
    }
}

/// Lets an on-demand refresh and the timed job share one sweep when they overlap.
public actor CalendarRefresher {
    private var inFlight: Task<EventsResponse, any Error>?

    public init() {}

    public func refresh(_ context: JobContext) async throws -> EventsResponse {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await CalendarCacheJob.refresh(context) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}
