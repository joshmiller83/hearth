import Foundation

/// What a rule looks for. Every field that's set must match (AND); within a
/// field, any value matches (OR). Text comparisons ignore case.
public struct MailMatch: Codable, Hashable, Sendable {
    public var fromContains: [String]
    /// The sender's domain ends with one of these ("greenhouse.io" matches "mail.greenhouse.io").
    public var fromDomains: [String]
    public var subjectContains: [String]
    /// Gmail label ids ("CATEGORY_PROMOTIONS") or the account's own label names ("job hunt").
    public var hasLabels: [String]
    public var githubReasons: [String]
    public var hasListId: Bool?
    public var unread: Bool?
    public var olderThanDays: Int?
    public var accounts: [String]

    public init(
        fromContains: [String] = [], fromDomains: [String] = [], subjectContains: [String] = [], hasLabels: [String] = [],
        githubReasons: [String] = [], hasListId: Bool? = nil, unread: Bool? = nil, olderThanDays: Int? = nil,
        accounts: [String] = []
    ) {
        self.fromContains = fromContains
        self.fromDomains = fromDomains
        self.subjectContains = subjectContains
        self.hasLabels = hasLabels
        self.githubReasons = githubReasons
        self.hasListId = hasListId
        self.unread = unread
        self.olderThanDays = olderThanDays
        self.accounts = accounts
    }

    public func matches(_ item: MailItem, labelNames: [String: String], now: Date) -> Bool {
        if !fromContains.isEmpty {
            let from = item.from.lowercased()
            guard fromContains.contains(where: { from.contains($0.lowercased()) }) else { return false }
        }
        if !fromDomains.isEmpty {
            let domain = item.senderDomain
            guard fromDomains.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) else { return false }
        }
        if !subjectContains.isEmpty {
            let subject = item.subject.lowercased()
            guard subjectContains.contains(where: { subject.contains($0.lowercased()) }) else { return false }
        }
        if !hasLabels.isEmpty {
            let mine = Set(item.labels.flatMap { [$0.lowercased(), labelNames[$0]?.lowercased() ?? ""] })
            guard hasLabels.contains(where: { mine.contains($0.lowercased()) }) else { return false }
        }
        if !githubReasons.isEmpty {
            guard let reason = item.githubReason, githubReasons.contains(reason) else { return false }
        }
        if let hasListId, (item.listId != nil) != hasListId { return false }
        if let unread, item.unread != unread { return false }
        if let days = olderThanDays, now.timeIntervalSince(item.date) < Double(days) * 86400 { return false }
        if !accounts.isEmpty, !accounts.contains(item.account) { return false }
        return true
    }
}

/// A sorting rule: what it matches and where that mail goes.
public struct MailRule: Codable, Hashable, Sendable, Identifiable {
    public enum Outcome: Codable, Hashable, Sendable {
        case queue(MailQueue, tag: String, bundle: String?)
        /// Never auto-filed: it stays in the inbox for the owner.
        case keep(tag: String)
    }

    public var id: String
    public var name: String
    public var enabled: Bool
    public var match: MailMatch
    public var outcome: Outcome

    public init(id: String, name: String, enabled: Bool = true, match: MailMatch, outcome: Outcome) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.match = match
        self.outcome = outcome
    }
}

public enum MailRules {
    /// The first enabled rule that matches decides; nil means no rule did (Claude sorts it).
    public static func classify(_ item: MailItem, rules: [MailRule], labelNames: [String: String] = [:], now: Date) -> TriagedMail? {
        guard let rule = rules.first(where: { $0.enabled && $0.match.matches(item, labelNames: labelNames, now: now) }) else { return nil }
        switch rule.outcome {
        case .queue(let queue, let tag, let bundle):
            return TriagedMail(item: item, queue: queue, tag: tag, reason: rule.name, sortedBy: .rule(rule.id), bundle: bundle)
        case .keep(let tag):
            return TriagedMail(item: item, queue: nil, tag: tag, reason: rule.name, sortedBy: .rule(rule.id))
        }
    }

    /// Hearth's starting rules, in order. Security first: it never auto-files.
    public static let defaults: [MailRule] = [
        MailRule(
            id: "security-sender", name: "Security alerts never auto-archive",
            match: MailMatch(fromContains: [
                "no-reply@accounts.google.com", "security-noreply", "account-security", "noreply@id.apple.com", "security@",
            ]),
            outcome: .keep(tag: "Security")),
        MailRule(
            id: "security-subject", name: "Security alerts never auto-archive",
            match: MailMatch(subjectContains: [
                "security alert", "new sign-in", "sign-in attempt", "suspicious", "verification code", "password reset",
                "unusual activity", "new login", "new device", "was your password changed",
            ]),
            outcome: .keep(tag: "Security")),
        MailRule(
            id: "job-label", name: "Labeled job hunt", match: MailMatch(hasLabels: ["job hunt"]),
            outcome: .queue(.jobHunt, tag: "Job hunt", bundle: nil)),
        MailRule(
            id: "job-ats", name: "From an applicant tracking system",
            match: MailMatch(fromDomains: [
                "greenhouse.io", "greenhouse-mail.io", "lever.co", "myworkday.com", "myworkdayjobs.com", "workday.com", "ashbyhq.com",
                "smartrecruiters.com", "icims.com", "jobvite.com", "bamboohr.com", "recruitee.com", "breezy.hr", "workable.com",
                "workablemail.com", "jazzhr.com", "applytojob.com", "paylocity.com", "ultipro.com", "successfactors.com", "taleo.net",
            ]),
            outcome: .queue(.jobHunt, tag: "Application", bundle: nil)),
        MailRule(
            id: "job-alerts", name: "Job alerts",
            match: MailMatch(fromContains: [
                "jobalerts", "jobs-noreply@linkedin.com", "jobs-listings@linkedin.com", "alert@indeed.com", "noreply@glassdoor.com",
                "wellfound", "dice.com", "ziprecruiter",
            ]),
            outcome: .queue(.jobHunt, tag: "Job alert", bundle: nil)),
        MailRule(
            id: "job-subject", name: "About an application",
            match: MailMatch(subjectContains: [
                "your application", "thank you for applying", "thanks for applying", "application received", "update on your application",
                "interview with",
            ]),
            outcome: .queue(.jobHunt, tag: "Application", bundle: nil)),
        MailRule(
            id: "invites", name: "Calendar invitations",
            match: MailMatch(subjectContains: ["invitation:", "updated invitation:"]),
            outcome: .queue(.reply, tag: "Invite", bundle: nil)),
        MailRule(
            id: "rsvps", name: "Replies to your invitations",
            match: MailMatch(subjectContains: ["accepted:", "declined:", "tentatively accepted:"]),
            outcome: .queue(.archive, tag: "RSVP", bundle: nil)),
        MailRule(
            id: "github-you", name: "GitHub wants you",
            match: MailMatch(
                fromContains: ["notifications@github.com"],
                githubReasons: [
                    "mention", "review_requested", "assign", "author", "manual", "security_alert",
                ]),
            outcome: .keep(tag: "GitHub")),
        MailRule(
            id: "github-chatter", name: "GitHub chatter is bundled",
            match: MailMatch(fromContains: ["notifications@github.com"]),
            outcome: .queue(.archive, tag: "Bundled", bundle: "GitHub")),
        MailRule(
            id: "old-promos", name: "Promos unopened for 90 days",
            match: MailMatch(hasLabels: ["CATEGORY_PROMOTIONS"], unread: true, olderThanDays: 90),
            outcome: .queue(.delete, tag: "Promo", bundle: nil)),
        MailRule(
            id: "promos", name: "Promotions", match: MailMatch(hasLabels: ["CATEGORY_PROMOTIONS"]),
            outcome: .queue(.archive, tag: "Promo", bundle: nil)),
        MailRule(
            id: "receipts", name: "Receipts and statements",
            match: MailMatch(subjectContains: [
                "receipt", "your order", "order confirmation", "has shipped", "delivered:", "out for delivery", "your statement",
                "statement is ready", "payment received", "invoice", "autopay",
            ]),
            outcome: .queue(.archive, tag: "Receipt", bundle: nil)),
        MailRule(
            id: "newsletters", name: "Newsletters and digests",
            match: MailMatch(hasLabels: ["CATEGORY_UPDATES", "CATEGORY_SOCIAL", "CATEGORY_FORUMS"], hasListId: true),
            outcome: .queue(.archive, tag: "Newsletter", bundle: nil)),
        MailRule(
            id: "social", name: "Social notifications", match: MailMatch(hasLabels: ["CATEGORY_SOCIAL"]),
            outcome: .queue(.archive, tag: "Social", bundle: nil)),
    ]
}
