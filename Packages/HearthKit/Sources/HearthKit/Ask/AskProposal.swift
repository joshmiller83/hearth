import Foundation

/// A step Ask proposes, checked and ready to show in "Waiting for your OK".
public struct AskProposal: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// A reminder on this phone.
        case remind
        /// A private hold on the owner's Google calendar.
        case hold
        /// An event on the family calendar (iCloud).
        case event
        /// A reply on an existing thread, held 30 seconds so Undo can stop it.
        case reply
        /// Text for the owner to copy.
        case note
        /// A page the owner finishes on.
        case link
    }

    public var id: String
    public var kind: Kind
    public var label: String
    public var detail: String
    public var done: String
    public var title: String
    public var start: Date?
    public var end: Date?
    public var account: String
    public var messageId: String
    public var text: String
    public var url: URL?

    public init(
        id: String, kind: Kind, label: String, detail: String = "", done: String = "", title: String = "", start: Date? = nil,
        end: Date? = nil, account: String = "", messageId: String = "", text: String = "", url: URL? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.detail = detail
        self.done = done
        self.title = title
        self.start = start
        self.end = end
        self.account = account
        self.messageId = messageId
        self.text = text
        self.url = url
    }

    /// Reads `propose_actions` input. Steps that don't hold up are left out and
    /// explained, so Claude hears why.
    public static func parse(_ input: JSONValue, household: Household, now: Date) -> (proposals: [AskProposal], problems: [String]) {
        var proposals: [AskProposal] = []
        var problems: [String] = []
        for (index, raw) in (input["actions"]?.arrayValue ?? []).prefix(6).enumerated() {
            func field(_ name: String) -> String { raw[name]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            func time(_ name: String) -> Date? { RFC3339.date(field(name), zone: household.zone) }
            let number = index + 1
            guard let kind = Kind(rawValue: field("kind")) else {
                problems.append("Step \(number): unknown kind \"\(field("kind"))\".")
                continue
            }
            var proposal = AskProposal(
                id: "p\(number)", kind: kind, label: field("label"), detail: field("detail"), done: field("done"),
                title: field("title"), start: time("start"), end: time("end"), account: field("account"),
                messageId: field("message_id"), text: field("text"))
            if proposal.label.isEmpty { proposal.label = proposal.title }
            if let problem = proposal.check(field("url"), household: household, now: now) {
                problems.append("Step \(number) (\(kind.rawValue)): \(problem)")
                continue
            }
            proposals.append(proposal)
        }
        if proposals.isEmpty, problems.isEmpty { problems.append("There were no steps.") }
        return (proposals, problems)
    }

    /// Fills in what's implied and returns what's wrong, if anything.
    mutating func check(_ link: String, household: Household, now: Date) -> String? {
        switch kind {
        case .remind:
            if title.isEmpty { return "a reminder needs a title." }
            guard let start else { return "a reminder needs a time (YYYY-MM-DDTHH:MM)." }
            if start < now.addingTimeInterval(-3600) { return "that time has passed." }
        case .hold, .event:
            if title.isEmpty { return "it needs a title." }
            guard let start, let end else { return "it needs a start and an end (YYYY-MM-DDTHH:MM)." }
            if end <= start { return "the end must come after the start." }
            if end.timeIntervalSince(start) > 12 * 3600 { return "keep it under 12 hours." }
            if end < now { return "that time has passed." }
            if kind == .hold {
                if account.isEmpty { account = household.primaryAccount }
                guard household.ownerAccounts.contains(account), !household.isGuarded(account) else {
                    return "holds go on the owner's own accounts (\(household.ownerAccounts.joined(separator: ", ")))."
                }
            }
        case .reply:
            if text.isEmpty { return "a reply needs its text." }
            if messageId.isEmpty { return "a reply needs the message_id it answers (from gmail_thread)." }
            guard household.ownerAccounts.contains(account), !household.isGuarded(account) else {
                return "replies go from the owner's own accounts (\(household.ownerAccounts.joined(separator: ", ")))."
            }
        case .note:
            if text.isEmpty { return "a note needs its text." }
        case .link:
            guard let url = URL(string: link), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
                return "a link needs an https URL."
            }
            self.url = url
        }
        if label.isEmpty { return "it needs a label." }
        if done.isEmpty { done = label }
        return nil
    }

    /// What Claude hears back about the steps it proposed.
    public static func receipt(_ proposals: [AskProposal], problems: [String], owner: String) -> String {
        var lines: [String] = []
        if !proposals.isEmpty {
            lines.append("Shown to \(owner) for approval: \(proposals.map(\.label).joined(separator: "; ")).")
        }
        if !problems.isEmpty {
            lines.append("Left out: " + problems.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }
}

/// What became of a turn's proposals, told to Claude at the start of the next
/// turn (the result it's owed for propose_actions).
public enum AskOutcome {
    public static func text(ran: [AskProposal], skipped: [AskProposal], failed: [(AskProposal, String)], undone: Bool) -> String {
        if undone { return "The owner ran these, then undid them: \(ran.map(\.label).joined(separator: "; "))." }
        var lines: [String] = []
        if !ran.isEmpty { lines.append("Done: \(ran.map(\.label).joined(separator: "; ")).") }
        if !failed.isEmpty { lines.append("Didn't work: " + failed.map { "\($0.0.label) (\($0.1))" }.joined(separator: "; ") + ".") }
        if !skipped.isEmpty { lines.append("Not run: \(skipped.map(\.label).joined(separator: "; ")).") }
        if lines.isEmpty { return "The owner hasn't run any of them." }
        return lines.joined(separator: " ")
    }
}
