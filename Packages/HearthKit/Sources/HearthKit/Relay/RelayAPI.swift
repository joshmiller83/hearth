import Foundation

/// The relay's routes. Every one needs `Authorization: Bearer <relay key>`
/// except `health` without the key, which answers only "ok".
public enum RelayPath {
    public static let health = "/v1/health"
    public static let calendarEvents = "/v1/calendar/events"
    public static let mailSnapshot = "/v1/mail/snapshot"
    public static let mailThreads = "/v1/mail/threads"
    public static let actions = "/v1/actions"
    public static let brief = "/v1/brief"
    public static let devices = "/v1/devices"
    public static let context = "/v1/context"
    public static let tools = "/v1/tools"
    public static let signals = "/v1/signals"
    public static let feeds = "/v1/feeds"
    public static let chats = "/v1/chats"
    public static let chatThread = "/v1/chats/thread"
}

/// Every error body: `{"error": true, "reason": "<a sentence for the owner>"}`.
public struct APIErrorBody: Codable, Equatable, Sendable {
    public var error: Bool
    public var reason: String

    public init(reason: String) {
        self.error = true
        self.reason = reason
    }
}

/// gmailkit, as the relay sees it.
public struct BridgeStatus: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable {
        case up
        case starting
        case down
    }

    public var state: State
    public var detail: String?
    public var since: Date?

    public init(state: State, detail: String? = nil, since: Date? = nil) {
        self.state = state
        self.detail = detail
        self.since = since
    }
}

/// When each of the relay's jobs last ran, for the Sources screen.
public struct JobStatus: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var lastRun: Date?
    public var lastSuccess: Date?
    public var lastError: String?
    public var nextRun: Date?
    public var id: String { name }

    public init(name: String, lastRun: Date? = nil, lastSuccess: Date? = nil, lastError: String? = nil, nextRun: Date? = nil) {
        self.name = name
        self.lastRun = lastRun
        self.lastSuccess = lastSuccess
        self.lastError = lastError
        self.nextRun = nextRun
    }
}

/// `GET /v1/health`. Without the key: just `status` and `version`. With it, the rest.
public struct HealthResponse: Codable, Hashable, Sendable {
    public var status: String
    public var version: String
    public var commit: String?
    public var now: Date?
    public var gmailkit: BridgeStatus?
    public var accounts: [Account]?
    public var household: Household?
    public var jobs: [JobStatus]?
    /// True when the relay has its own Claude key (the brief, sorting leftovers).
    public var claude: Bool?
    /// True when the relay can send pushes (an APNs key is installed).
    public var push: Bool?
    /// Whether the Mac's Messages helper can read texts.
    public var chats: ChatSourceStatus?
    /// Every chat source's status: Messages, then each bridge the Mac runs.
    public var chatSources: [ChatSourceStatus]?

    public init(
        status: String, version: String, commit: String? = nil, now: Date? = nil, gmailkit: BridgeStatus? = nil,
        accounts: [Account]? = nil, household: Household? = nil, jobs: [JobStatus]? = nil,
        claude: Bool? = nil, push: Bool? = nil, chats: ChatSourceStatus? = nil, chatSources: [ChatSourceStatus]? = nil
    ) {
        self.status = status
        self.version = version
        self.commit = commit
        self.now = now
        self.gmailkit = gmailkit
        self.accounts = accounts
        self.household = household
        self.jobs = jobs
        self.claude = claude
        self.push = push
        self.chats = chats
        self.chatSources = chatSources
    }
}

/// A source the relay couldn't read on its last pass ("ek: token expired").
public struct SourceProblem: Codable, Hashable, Sendable {
    public var source: String
    public var message: String

    public init(source: String, message: String) {
        self.source = source
        self.message = message
    }
}

/// `GET /v1/calendar/events?from=…&to=…[&refresh=1]`: every Google calendar,
/// partner events already reduced to busy-only.
public struct EventsResponse: Codable, Hashable, Sendable {
    public var events: [AgendaEvent]
    public var calendars: [CalendarInfo]
    public var fetchedAt: Date
    public var problems: [SourceProblem]

    public init(events: [AgendaEvent], calendars: [CalendarInfo], fetchedAt: Date, problems: [SourceProblem] = []) {
        self.events = events
        self.calendars = calendars
        self.fetchedAt = fetchedAt
        self.problems = problems
    }
}

/// `POST /v1/actions`: approved actions to run now or at their `notBefore`.
public struct ActionBatch: Codable, Hashable, Sendable {
    public var actions: [ApprovedAction]

    public init(actions: [ApprovedAction]) {
        self.actions = actions
    }
}

/// The answer to `POST /v1/actions` and `GET /v1/actions?ids=…`.
public struct ActionStatuses: Codable, Hashable, Sendable {
    public var actions: [ActionStatus]

    public init(actions: [ActionStatus]) {
        self.actions = actions
    }
}

/// `DELETE /v1/actions/:id` cancels a pending action (Undo, or a scheduled send
/// taken back). The answer is its status.
public struct CancelResponse: Codable, Hashable, Sendable {
    public var action: ActionStatus

    public init(action: ActionStatus) {
        self.action = action
    }
}

/// `POST /v1/context`: what the phone knows that the relay's jobs need — the
/// owner's switches, the Apple calendars (EventKit lives on the phone), and
/// the notes the brief and people ideas draw on.
public struct PhoneContext: Codable, Hashable, Sendable {
    public var rules: HouseRules
    /// Apple (iCloud) events for the next two weeks, so the brief sees the family calendar.
    public var appleEvents: [AgendaEvent]
    /// The mail rules as the owner set them in Sources; nil keeps the relay's.
    public var mailRules: [MailRule]?
    /// Mail the owner left out of its queue (`TriagedMail.id`s), so the brief doesn't count it.
    public var leftOut: [String]?
    public var uploadedAt: Date

    public init(
        rules: HouseRules, appleEvents: [AgendaEvent] = [], mailRules: [MailRule]? = nil, leftOut: [String]? = nil, uploadedAt: Date
    ) {
        self.rules = rules
        self.appleEvents = appleEvents
        self.mailRules = mailRules
        self.leftOut = leftOut
        self.uploadedAt = uploadedAt
    }
}

/// `POST /v1/tools/gmail_search`: Ask's mail search, read-only.
public struct GmailSearchRequest: Codable, Hashable, Sendable {
    public static let maxLimit = 25

    public var query: String
    /// An account alias, or "all".
    public var account: String
    public var limit: Int

    public init(query: String, account: String = "all", limit: Int = 10) {
        self.query = query
        self.account = account
        self.limit = limit
    }
}

public struct GmailSearchResponse: Codable, Hashable, Sendable {
    /// Newest first, at most the request's limit across every account searched.
    public var messages: [MailItem]
    public var problems: [SourceProblem]

    public init(messages: [MailItem], problems: [SourceProblem] = []) {
        self.messages = messages
        self.problems = problems
    }
}
