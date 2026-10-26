import Fluent
import Foundation
import HearthKit
import RelayCore

/// 6:30 AM: Opus writes the brief from the calendars and the queues, and a
/// push goes out when quiet hours end. Skipped when the owner turned the
/// brief off, or the relay has no Claude key.
public struct BriefJob: RelayJob {
    public static let jobName = "brief"
    public var name: String { Self.jobName }
    public var schedule: JobSchedule { .daily(hour: 6, minute: 30) }

    public init() {}

    public func run(_ context: JobContext) async throws {
        _ = try await Self.write(context)
    }

    /// Writes today's brief (also `Run brief`). Nil when it's off or there's no key.
    @discardableResult
    public static func write(_ context: JobContext, push: Bool = true) async throws -> Brief? {
        let cache = context.cache
        let phone = try await cache.get(PhoneContext.self, Cache.context)
        let rules = phone?.rules ?? HouseRules()
        guard rules.morningBrief else {
            context.logger.info("brief: off in the owner's rules")
            return nil
        }
        guard let claude = context.claude else {
            context.logger.info("brief: the relay has no Claude key")
            return nil
        }
        let now = context.now()
        let google = try await cache.get(EventsResponse.self, Cache.events)?.events ?? []
        let agenda = Agenda(events: google + (phone?.appleEvents ?? []), household: context.household)
        let mail = try await cache.get(MailSnapshot.self, Cache.mailSnapshot)
        let input = BriefInput.gather(agenda: agenda, mail: mail, now: now)
        let (reply, response) = try await claude.structured(BriefPrompt.request(input), as: BriefPrompt.Reply.self)
        let brief = BriefPrompt.brief(reply, input: input)
        try await cache.set(brief, Cache.brief, now: now)
        context.logger.info("brief: written (\(response.usage.outputTokens) tokens out)")
        if push {
            let alert = PushAlert(title: "Good morning, \(context.household.ownerName)", body: brief.headline, kind: "brief")
            try await PushQueue.enqueue(alert, quietHours: rules.quietHours, zone: context.household.zone, now: now, db: context.db)
        }
        return brief
    }
}
