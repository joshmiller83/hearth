import Foundation

/// Something Hearth may do for the owner once they've said yes. Claude and the
/// relay's jobs only ever *propose* these; the phone sends them to the relay
/// after a tap, with the moment of approval and a key that makes retries safe.
public enum ActionKind: Codable, Hashable, Sendable {
    /// Gmail: archive, trash (never permanent), mark read, or add/remove labels, on one account.
    case modifyMail(account: String, messageIds: [String], change: MailChange)
    /// Gmail: send a reply on a thread. With `notBefore` the relay holds it until then.
    case reply(account: String, messageId: String, body: String, replyAll: Bool)
    /// Google Calendar: answer an invite.
    case rsvp(account: String, calendarId: String, eventId: String, response: RSVP)
    /// Google Calendar: a private hold (no guests, no invite) on the owner's account.
    case createHold(account: String, title: String, start: Date, end: Date, notes: String?)
    /// Google Calendar: remove a hold Hearth made.
    case deleteHold(account: String, calendarId: String, eventId: String)

    public var account: String {
        switch self {
        case .modifyMail(let a, _, _), .reply(let a, _, _, _), .rsvp(let a, _, _, _),
            .createHold(let a, _, _, _, _), .deleteHold(let a, _, _):
            a
        }
    }

    /// True for actions that write to a calendar (the surprise guard's concern).
    public var touchesCalendar: Bool {
        switch self {
        case .rsvp, .createHold, .deleteHold: true
        case .modifyMail, .reply: false
        }
    }

    /// "Archive 41 messages on team", "Reply to Priya on team", "RSVP Maybe".
    public var summary: String {
        switch self {
        case .modifyMail(let account, let ids, let change):
            "\(change.verb) \(ids.count) message\(ids.count == 1 ? "" : "s") on \(account)"
        case .reply(let account, _, _, _): "Send a reply from \(account)"
        case .rsvp(_, _, _, let response): "RSVP \(response.buttonLabel)"
        case .createHold(let account, let title, _, _, _): "Hold \"\(title)\" on \(account)"
        case .deleteHold(let account, _, _): "Remove a hold on \(account)"
        }
    }
}

/// One change to a set of messages. Trash is the strongest: Hearth never deletes for good.
public struct MailChange: Codable, Hashable, Sendable {
    public var archive: Bool
    public var trash: Bool
    public var markRead: Bool
    public var addLabels: [String]
    public var removeLabels: [String]

    public init(archive: Bool = false, trash: Bool = false, markRead: Bool = false, addLabels: [String] = [], removeLabels: [String] = []) {
        self.archive = archive
        self.trash = trash
        self.markRead = markRead
        self.addLabels = addLabels
        self.removeLabels = removeLabels
    }

    public static let archive = MailChange(archive: true, markRead: true)
    public static let trash = MailChange(trash: true, markRead: true)
    public static let markRead = MailChange(markRead: true)

    /// Moving a message back to the inbox, for Undo.
    public static let restoreToInbox = MailChange(addLabels: ["INBOX"], removeLabels: ["TRASH"])

    public var verb: String {
        if trash { return "Move to Trash" }
        if archive { return "Archive" }
        if markRead && addLabels.isEmpty && removeLabels.isEmpty { return "Mark read" }
        if let label = addLabels.first { return "Label \(label)" }
        return "Change"
    }
}

/// Where an action came from, for the policies that care.
public enum ActionContext: String, Codable, Hashable, Sendable {
    case inbox
    case plans
    case ask
    case capture
    /// The partner planner: the surprise guard applies.
    case surprise
}

/// An action the owner approved, as the phone sends it to `POST /v1/actions`.
public struct ApprovedAction: Codable, Hashable, Sendable, Identifiable {
    /// The idempotency key: the relay runs each id once, whatever retries arrive.
    public var id: String
    public var kind: ActionKind
    public var context: ActionContext
    /// When the owner tapped. The relay refuses actions without one.
    public var approvedAt: Date
    /// Run no earlier than this ("Send tomorrow 8 AM").
    public var notBefore: Date?

    public init(id: String = UUID().uuidString, kind: ActionKind, context: ActionContext, approvedAt: Date, notBefore: Date? = nil) {
        self.id = id
        self.kind = kind
        self.context = context
        self.approvedAt = approvedAt
        self.notBefore = notBefore
    }
}

public enum ActionState: String, Codable, Hashable, Sendable {
    /// Waiting for `notBefore`, or queued to run.
    case pending
    case done
    case failed
    /// The owner took it back (Undo) before it ran.
    case cancelled
    /// A policy refused it; it never ran.
    case refused
}

/// What the relay reports about one action.
public struct ActionStatus: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: ActionKind
    public var state: ActionState
    public var notBefore: Date?
    public var updatedAt: Date
    /// A sentence for the owner when it failed or was refused.
    public var message: String?
    /// What the action produced, e.g. the event an RSVP returned or a hold's event id.
    public var result: JSONValue?

    public init(
        id: String, kind: ActionKind, state: ActionState, notBefore: Date? = nil, updatedAt: Date,
        message: String? = nil, result: JSONValue? = nil
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.notBefore = notBefore
        self.updatedAt = updatedAt
        self.message = message
        self.result = result
    }
}
