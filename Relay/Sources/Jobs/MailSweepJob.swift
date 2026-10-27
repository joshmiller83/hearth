import Fluent
import Foundation
import HearthKit
import RelayCore

/// Every 15 minutes: every inbox, sorted into the four queues. Rules first (no
/// AI); Haiku only for what no rule placed, once per message. Nothing moves:
/// the queues wait for the owner's approval on the phone.
public struct MailSweepJob: RelayJob {
    public static let jobName = "mail"
    public var name: String { Self.jobName }
    public var schedule: JobSchedule { .every(15 * 60) }

    /// The newest inbox messages per account.
    public static let inboxLimit = 250
    /// The 90-day-old unopened promos live further back than that.
    public static let oldPromoQuery = "in:inbox category:promotions is:unread older_than:90d"

    public init() {}

    public func run(_ context: JobContext) async throws {
        _ = try await Self.sweep(context)
    }

    public static func sweep(_ context: JobContext) async throws -> MailSnapshot {
        let google = context.google
        let cache = context.cache
        let now = context.now()
        let aliases = await google.aliases()
        func alias(_ email: String) -> String { aliases[email.lowercased()] ?? email }

        let labels = try await labelNames(context)
        let previous = try await cache.get(MailSnapshot.self, Cache.mailSnapshot)
        // Old promos sit past the newest few hundred, so they get their own (usually tiny) search.
        let rows =
            try await google.search(query: "in:inbox", account: "all", limit: inboxLimit, metadataOnly: true)
            + google.search(query: oldPromoQuery, account: "all", limit: 200, metadataOnly: true)

        var problems: [SourceProblem] = []
        var items: [MailItem] = []
        var seen = Set<String>()
        for row in rows {
            if let error = row.error {
                problems.append(SourceProblem(source: alias(row.account), message: error))
                continue
            }
            guard let item = MailItem(row: row, alias: alias), seen.insert(item.account + ":" + item.id).inserted else { continue }
            items.append(item)
        }

        let rules = try await cache.get([MailRule].self, Cache.mailRules) ?? MailRules.defaults
        let stored = try await storedTriage(ids: items.map { $0.account + ":" + $0.id }, db: context.db)
        var triaged: [TriagedMail] = []
        var leftovers: [MailItem] = []
        for item in items {
            let key = item.account + ":" + item.id
            if let record = stored[key], record.handledAt != nil { continue }
            if let byRule = MailRules.classify(item, rules: rules, labelNames: labels[item.account] ?? [:], now: now) {
                triaged.append(byRule)
            } else if let record = stored[key], record.sorter == "claude" || context.claude == nil {
                triaged.append(
                    TriagedMail(
                        item: item, queue: record.queue.flatMap(MailQueue.init(rawValue:)), tag: record.tag, reason: record.reason,
                        sortedBy: record.sorter == "claude" ? .claude : .unsorted))
            } else {
                leftovers.append(item)
            }
        }

        let sortedLeftovers = await sortLeftovers(leftovers, labels: labels, context: context)
        for item in sortedLeftovers {
            let model = MailTriageModel(triaged: item, now: now)
            if let existing = try await MailTriageModel.find(model.id, on: context.db) {
                existing.queue = model.queue
                existing.tag = model.tag
                existing.reason = model.reason
                existing.sorter = model.sorter
                existing.classifiedAt = now
                try await existing.update(on: context.db)
            } else {
                try await model.create(on: context.db)
            }
        }
        triaged += sortedLeftovers

        let since = previous?.generatedAt ?? now.addingTimeInterval(-12 * 3600)
        var jobHunt: [String: String] = [:]
        for (account, names) in labels {
            if let id = names.first(where: { $0.value.lowercased() == "job hunt" })?.key { jobHunt[account] = id }
        }
        let snapshot = MailSnapshot(
            generatedAt: now, accounts: Array(Set(items.map(\.account))).sorted(),
            items: triaged.sorted { $0.item.date > $1.item.date },
            newCount: items.filter { $0.date > since }.count, jobHuntLabels: jobHunt, problems: problems)
        try await cache.set(snapshot, Cache.mailSnapshot, now: now)
        try await prune(keep: Set(items.map { $0.account + ":" + $0.id }), db: context.db, now: now)
        let byClaude = sortedLeftovers.filter { $0.sortedBy == .claude }.count
        context.logger.info(
            "mail: \(items.count) inbox messages, \(byClaude) newly sorted by Claude, \(sortedLeftovers.count - byClaude) unsorted, \(problems.count) problems"
        )
        return snapshot
    }

    /// Each account's label names, refreshed once a day.
    static func labelNames(_ context: JobContext) async throws -> [String: [String: String]] {
        let cache = context.cache
        if let saved = try await cache.get([String: [String: String]].self, Cache.mailLabels),
            let updated = try await cache.updatedAt(Cache.mailLabels), context.now().timeIntervalSince(updated) < 86400
        {
            return saved
        }
        var out: [String: [String: String]] = [:]
        for account in try await context.google.accounts() where account.enabled && account.authorized {
            guard let rows = try? await context.google.labels(account: account.alias) else { continue }
            out[account.alias] = Dictionary(rows.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        }
        try await cache.set(out, Cache.mailLabels, now: context.now())
        return out
    }

    /// Haiku, in batches; without the relay's own Claude key, they stay unsorted (kept in the inbox).
    static func sortLeftovers(_ items: [MailItem], labels: [String: [String: String]], context: JobContext) async -> [TriagedMail] {
        guard !items.isEmpty else { return [] }
        guard let claude = context.claude else {
            return items.map {
                TriagedMail(item: $0, queue: nil, tag: "Needs a look", reason: TriagedMail.noKeyReason, sortedBy: .unsorted)
            }
        }
        var out: [TriagedMail] = []
        var start = 0
        while start < items.count {
            let batch = Array(items[start..<min(start + SortPrompt.batchSize, items.count)])
            start += SortPrompt.batchSize
            let names = labels.values.reduce(into: [String: String]()) { $0.merge($1) { a, _ in a } }
            do {
                let (reply, _) = try await claude.structured(
                    SortPrompt.request(batch, household: context.household, labelNames: names), as: SortPrompt.Reply.self)
                out += SortPrompt.triage(batch, reply: reply)
            } catch {
                context.logger.error("mail: Haiku couldn't sort \(batch.count) messages: \(error)")
                out += batch.map { TriagedMail(item: $0, queue: nil, tag: "Needs a look", reason: "Not sorted yet", sortedBy: .unsorted) }
            }
        }
        return out
    }

    static func storedTriage(ids: [String], db: any Database) async throws -> [String: MailTriageModel] {
        var out: [String: MailTriageModel] = [:]
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            start += 500
            for model in try await MailTriageModel.query(on: db).filter(\.$id ~~ chunk).all() {
                if let id = model.id { out[id] = model }
            }
        }
        return out
    }

    /// Forget sortings for mail that left the inbox more than a month ago.
    static func prune(keep: Set<String>, db: any Database, now: Date) async throws {
        let old = try await MailTriageModel.query(on: db).filter(\.$classifiedAt < now.addingTimeInterval(-30 * 86400)).all()
        for model in old where !keep.contains(model.id ?? "") { try await model.delete(on: db) }
    }
}
