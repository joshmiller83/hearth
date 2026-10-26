import Foundation

/// The four triage queues. Mail outside them stays in the inbox ("kept").
public enum MailQueue: String, Codable, Sendable, CaseIterable {
    case reply
    case jobHunt
    case archive
    case delete

    public var label: String {
        switch self {
        case .reply: "Reply"
        case .jobHunt: "Job hunt"
        case .archive: "Archive"
        case .delete: "Delete"
        }
    }
}

/// One message in an inbox, from gmailkit's metadata sweep.
public struct MailItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var threadId: String
    /// The account alias ("team").
    public var account: String
    public var from: String
    public var to: String
    public var cc: String
    public var subject: String
    public var snippet: String
    public var date: Date
    /// Gmail label ids ("INBOX", "UNREAD", "CATEGORY_PROMOTIONS", "Label_7").
    public var labels: [String]
    public var unread: Bool
    /// X-GitHub-Reason: subscribed, mention, review_requested, …
    public var githubReason: String?
    public var listId: String?

    public init(
        id: String, threadId: String, account: String, from: String, to: String = "", cc: String = "", subject: String,
        snippet: String = "", date: Date, labels: [String] = ["INBOX"], unread: Bool = true, githubReason: String? = nil,
        listId: String? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.account = account
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.snippet = snippet
        self.date = date
        self.labels = labels
        self.unread = unread
        self.githubReason = githubReason
        self.listId = listId
    }

    /// A gmailkit metadata row as an item, or nil for error rows.
    public init?(row: GmailkitMessageRow, alias: (String) -> String) {
        guard row.error == nil, let id = row.id, let thread = row.thread_id else { return nil }
        self.init(
            id: id, threadId: thread, account: alias(row.account), from: row.from ?? "", to: row.to ?? "", cc: row.cc ?? "",
            subject: (row.subject?.isEmpty ?? true) ? "(no subject)" : row.subject!, snippet: Self.clean(row.snippet ?? ""),
            date: row.date.flatMap { RFC3339.date($0) } ?? .distantPast, labels: row.labels ?? [], unread: row.unread ?? false,
            githubReason: (row.github_reason?.isEmpty ?? true) ? nil : row.github_reason,
            listId: (row.list_id?.isEmpty ?? true) ? nil : row.list_id)
    }

    /// Gmail snippets carry HTML entities.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "&#39;", with: "’").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(
                of: "&gt;", with: ">")
    }

    /// "Priya Raman" from "Priya Raman <priya@example.com>", or the address.
    public var senderName: String {
        let raw = from.trimmingCharacters(in: .whitespaces)
        if let angle = raw.firstIndex(of: "<") {
            let name = raw[..<angle].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !name.isEmpty { return name }
        }
        return senderEmail
    }

    /// "priya@example.com".
    public var senderEmail: String {
        let raw = from.trimmingCharacters(in: .whitespaces)
        if let open = raw.firstIndex(of: "<"), let close = raw.lastIndex(of: ">"), open < close {
            return String(raw[raw.index(after: open)..<close]).lowercased()
        }
        return raw.lowercased()
    }

    public var senderDomain: String {
        senderEmail.split(separator: "@").last.map(String.init) ?? ""
    }

    public var initial: String { senderName.first.map { String($0).uppercased() } ?? "?" }
}

/// How a message got its queue.
public enum Sorter: Codable, Hashable, Sendable {
    case rule(String)
    case claude
    /// Nothing placed it (the relay has no Claude key yet).
    case unsorted
}

/// A message and where triage put it.
public struct TriagedMail: Codable, Hashable, Sendable, Identifiable {
    public var item: MailItem
    /// Nil keeps it in the inbox (security alerts never auto-file).
    public var queue: MailQueue?
    /// The chip on the row: "Needs you", "Invite", "Receipt", "Newsletter", "Promo", "Bundled", "Security".
    public var tag: String
    public var reason: String
    public var sortedBy: Sorter
    /// Rows with the same bundle show as one ("GitHub · 23 updates").
    public var bundle: String?

    public init(item: MailItem, queue: MailQueue?, tag: String, reason: String, sortedBy: Sorter, bundle: String? = nil) {
        self.item = item
        self.queue = queue
        self.tag = tag
        self.reason = reason
        self.sortedBy = sortedBy
        self.bundle = bundle
    }

    public var id: String { item.account + ":" + item.id }
}

/// `GET /v1/mail/snapshot`: every inbox, triaged.
public struct MailSnapshot: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var accounts: [String]
    public var items: [TriagedMail]
    /// Messages that arrived since the previous sweep the owner saw ("64 new overnight").
    public var newCount: Int
    /// Account alias → its "job hunt" label id, where the account has one.
    public var jobHuntLabels: [String: String]
    public var problems: [SourceProblem]

    public init(
        generatedAt: Date, accounts: [String], items: [TriagedMail], newCount: Int = 0, jobHuntLabels: [String: String] = [:],
        problems: [SourceProblem] = []
    ) {
        self.generatedAt = generatedAt
        self.accounts = accounts
        self.items = items
        self.newCount = newCount
        self.jobHuntLabels = jobHuntLabels
        self.problems = problems
    }

    public func items(in queue: MailQueue, account: String? = nil) -> [TriagedMail] {
        items.filter { $0.queue == queue && (account == nil || $0.item.account == account) }
            .sorted { $0.item.date > $1.item.date }
    }

    public func kept(account: String? = nil) -> [TriagedMail] {
        items.filter { $0.queue == nil && (account == nil || $0.item.account == account) }
    }

    /// Without the messages Hearth just filed.
    public func removing(account: String, ids: Set<String>) -> MailSnapshot {
        var out = self
        out.items.removeAll { $0.item.account == account && ids.contains($0.item.id) }
        return out
    }
}

/// `GET /v1/mail/threads/:account/:id`: a thread's messages with their text.
public struct ThreadMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var from: String
    public var to: String
    public var cc: String
    public var date: Date
    public var subject: String
    public var body: String
    public var labels: [String]

    public init(id: String, from: String, to: String, cc: String = "", date: Date, subject: String, body: String, labels: [String] = []) {
        self.id = id
        self.from = from
        self.to = to
        self.cc = cc
        self.date = date
        self.subject = subject
        self.body = body
        self.labels = labels
    }

    public init?(row: GmailkitMessageRow) {
        guard row.error == nil, let id = row.id else { return nil }
        let text = row.body_text.flatMap { $0.isEmpty ? nil : $0 } ?? row.body_html.map(Self.stripHTML) ?? row.snippet ?? ""
        self.init(
            id: id, from: row.from ?? "", to: row.to ?? "", cc: row.cc ?? "",
            date: row.date.flatMap { RFC3339.date($0) } ?? .distantPast, subject: row.subject ?? "",
            body: Self.trimQuoted(text), labels: row.labels ?? [])
    }

    /// Drops the quoted history under "On … wrote:" and signatures' "--".
    static func trimQuoted(_ text: String) -> String {
        var lines: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") { break }
            if trimmed.hasPrefix("On "), trimmed.hasSuffix("wrote:") { break }
            if trimmed == "--" || trimmed == "-- " { break }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripHTML(_ html: String) -> String {
        var out = ""
        var inTag = false
        for character in html {
            if character == "<" {
                inTag = true
            } else if character == ">" {
                inTag = false
                out.append(" ")
            } else if !inTag {
                out.append(character)
            }
        }
        return MailItem.clean(out).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public struct ThreadResponse: Codable, Hashable, Sendable {
    public var account: String
    public var threadId: String
    public var messages: [ThreadMessage]

    public init(account: String, threadId: String, messages: [ThreadMessage]) {
        self.account = account
        self.threadId = threadId
        self.messages = messages
    }
}
