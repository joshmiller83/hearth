import Foundation

// Text conversations: iMessage and SMS, read from the Mac's Messages database by
// `hearth-messages`, and WhatsApp and Messenger chats, which the relay reads from
// the Mac's bridges (`BridgedChats`). Read only: Hearth never sends a message.

/// One conversation.
public struct ChatThread: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Where it came from: "imessage", "whatsapp", "facebook" (`ChatSource`).
    public var source: String
    /// A named group's name.
    public var name: String?
    /// The other people in it: phone numbers or emails, as the source has them, or a
    /// network's own id ("whatsapp:lid-…", "facebook:…") where it has no number.
    public var handles: [String]
    /// "iMessage", "SMS", "RCS", "WhatsApp", "Messenger".
    public var service: String
    /// The names the network gives the people in it, by handle; Contacts' names come first.
    public var names: [String: String]?

    public init(
        id: String, source: String = ChatSource.iMessage, name: String? = nil, handles: [String], service: String = "iMessage",
        names: [String: String]? = nil
    ) {
        self.id = id
        self.source = source
        self.name = name
        self.handles = handles
        self.service = service
        self.names = names
    }

    public var isGroup: Bool { handles.count > 1 }
}

/// One message in a conversation.
public struct ChatMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var threadId: String
    public var fromMe: Bool
    /// Who sent it; nil when it's the owner's.
    public var sender: String?
    public var date: Date
    public var text: String
    /// It carried a photo or a file (Hearth doesn't read those).
    public var hasAttachment: Bool

    public init(
        id: String, threadId: String, fromMe: Bool, sender: String? = nil, date: Date, text: String, hasAttachment: Bool = false
    ) {
        self.id = id
        self.threadId = threadId
        self.fromMe = fromMe
        self.sender = sender
        self.date = date
        self.text = text
        self.hasAttachment = hasAttachment
    }
}

public enum ChatSource {
    public static let iMessage = "imessage"
    /// The bridges' network ids, as the mautrix bridges name themselves.
    public static let whatsApp = "whatsapp"
    public static let messenger = "facebook"
    /// What the relay's merged export says it holds.
    public static let all = "all"

    /// "Messages", "WhatsApp", "Messenger".
    public static func label(_ source: String) -> String {
        switch source {
        case iMessage: return "Messages"
        case whatsApp: return "WhatsApp"
        case messenger: return "Messenger"
        default: return source.capitalized
        }
    }
}

/// What `hearth-messages` writes and the relay reads: recent conversations, oldest message first.
public struct ChatExport: Codable, Hashable, Sendable {
    public var exportedAt: Date
    public var source: String
    /// The window: messages since then.
    public var since: Date
    public var threads: [ChatThread]
    public var messages: [ChatMessage]

    public init(exportedAt: Date, source: String = ChatSource.iMessage, since: Date, threads: [ChatThread], messages: [ChatMessage]) {
        self.exportedAt = exportedAt
        self.source = source
        self.since = since
        self.threads = threads
        self.messages = messages
    }

    /// Several sources' exports as one, for the routes and Ask.
    public static func merged(_ exports: [ChatExport]) -> ChatExport? {
        guard let first = exports.first else { return nil }
        guard exports.count > 1 else { return first }
        return ChatExport(
            exportedAt: exports.map(\.exportedAt).max() ?? first.exportedAt, source: ChatSource.all,
            since: exports.map(\.since).min() ?? first.since, threads: exports.flatMap(\.threads), messages: exports.flatMap(\.messages))
    }
}

/// Whether a source can be read, as of its last check (the helper's run, or the relay's).
public struct ChatSourceStatus: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable {
        case ok
        /// The helper isn't allowed to read the Messages database (Full Disk Access).
        case needsAccess
        case failed
        /// No helper has ever reported.
        case notInstalled
        /// The helper stopped reporting.
        case notRunning
    }

    public var state: State
    public var checkedAt: Date?
    public var exportedAt: Date?
    public var threads: Int
    public var messages: Int
    public var message: String?
    /// Which source (`ChatSource`); nil means iMessage, as `hearth-messages` writes it.
    public var source: String?

    public init(
        state: State, checkedAt: Date? = nil, exportedAt: Date? = nil, threads: Int = 0, messages: Int = 0, message: String? = nil,
        source: String? = nil
    ) {
        self.state = state
        self.checkedAt = checkedAt
        self.exportedAt = exportedAt
        self.threads = threads
        self.messages = messages
        self.message = message
        self.source = source
    }

    public static let notInstalled = ChatSourceStatus(state: .notInstalled)
}

/// A conversation as the phone lists it: its last message, and whether it's waiting on the owner.
public struct ChatSummary: Codable, Hashable, Sendable, Identifiable {
    public var thread: ChatThread
    public var last: ChatMessage
    /// Their messages since the owner last wrote, oldest first (up to five).
    public var unanswered: [ChatMessage]
    /// They asked something and the owner hasn't answered (`Chats.isWaiting`).
    public var waiting: Bool

    public init(thread: ChatThread, last: ChatMessage, unanswered: [ChatMessage], waiting: Bool) {
        self.thread = thread
        self.last = last
        self.unanswered = unanswered
        self.waiting = waiting
    }

    public var id: String { thread.id }
    /// Changes when they write again, so leaving one out lasts until the next message.
    public var waitingId: String { thread.id + "#" + last.id }
}

/// `GET /v1/chats`.
public struct ChatsResponse: Codable, Hashable, Sendable {
    /// Messages (iMessage and SMS).
    public var status: ChatSourceStatus
    /// Most recent first, from every source that can be read.
    public var threads: [ChatSummary]
    /// Every source's status, Messages first, then the bridges the Mac runs.
    public var sources: [ChatSourceStatus]?

    public init(status: ChatSourceStatus, threads: [ChatSummary], sources: [ChatSourceStatus]? = nil) {
        self.status = status
        self.threads = threads
        self.sources = sources
    }
}

/// `GET /v1/chats/:id`: a conversation's latest messages, oldest first.
public struct ChatThreadResponse: Codable, Hashable, Sendable {
    public var thread: ChatThread
    public var messages: [ChatMessage]

    public init(thread: ChatThread, messages: [ChatMessage]) {
        self.thread = thread
        self.messages = messages
    }
}

/// `POST /v1/tools/chats_search`: Ask's text search, read-only.
public struct ChatSearchRequest: Codable, Hashable, Sendable {
    public static let maxLimit = 40

    /// Words that must all appear; empty matches every message.
    public var query: String
    /// Only conversations with these people (phone numbers or emails); empty means anyone.
    public var handles: [String]
    public var days: Int
    public var limit: Int
    /// Also conversations where the network's name for someone matches this ("Dana"),
    /// for chats with no phone number to find in Contacts.
    public var person: String?

    public init(query: String, handles: [String] = [], days: Int = 30, limit: Int = 20, person: String? = nil) {
        self.query = query
        self.handles = handles
        self.days = days
        self.limit = limit
        self.person = person
    }
}

public struct ChatSearchResponse: Codable, Hashable, Sendable {
    /// Newest first.
    public var messages: [ChatMessage]
    /// The conversations they're from.
    public var threads: [ChatThread]

    public init(messages: [ChatMessage], threads: [ChatThread]) {
        self.messages = messages
        self.threads = threads
    }
}

public enum Chats {
    /// How long a question waits on the owner before it's left to Messages.
    public static let waitingWindow: TimeInterval = 72 * 3600

    /// Each conversation's last message and what's waiting, most recent first.
    public static func summaries(_ export: ChatExport, ownerName: String, now: Date, limit: Int = 40) -> [ChatSummary] {
        let byThread = Dictionary(grouping: export.messages, by: \.threadId)
        var out: [ChatSummary] = []
        for thread in export.threads {
            guard let messages = byThread[thread.id]?.sorted(by: { $0.date < $1.date }), let last = messages.last else { continue }
            let unanswered = Array(messages.reversed().prefix { !$0.fromMe }.reversed())
            out.append(
                ChatSummary(
                    thread: thread, last: last, unanswered: Array(unanswered.suffix(5)),
                    waiting: isWaiting(thread: thread, unanswered: unanswered, ownerName: ownerName, now: now)))
        }
        return Array(out.sorted { $0.last.date > $1.last.date }.prefix(limit))
    }

    /// They asked and the owner hasn't written since: a question in their latest run of
    /// messages, in the last three days, from a person (not a short code or a no-reply
    /// address). In a group, only when it also names the owner.
    public static func isWaiting(thread: ChatThread, unanswered: [ChatMessage], ownerName: String, now: Date) -> Bool {
        guard let newest = unanswered.last, now.timeIntervalSince(newest.date) < waitingWindow else { return false }
        guard thread.handles.contains(where: ChatHandle.isPerson) else { return false }
        let texts = unanswered.map { $0.text.lowercased() }
        guard texts.contains(where: { $0.contains("?") }) else { return false }
        guard thread.isGroup else { return true }
        let name = ownerName.lowercased()
        guard !name.isEmpty else { return false }
        return texts.contains { text in
            text.split(whereSeparator: { !$0.isLetter }).contains { $0 == Substring(name) }
        }
    }

    /// Ask's search: every word of the query, in the window, with the people asked for; newest first.
    public static func search(_ export: ChatExport, _ request: ChatSearchRequest, now: Date) -> ChatSearchResponse {
        let since = now.addingTimeInterval(-Double(max(1, request.days)) * 86400)
        let words = request.query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let wanted = Set(request.handles.map(ChatHandle.normalize))
        let person = (request.person ?? "").trimmingCharacters(in: .whitespaces)
        let threads = Dictionary(export.threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func isWanted(_ thread: ChatThread) -> Bool {
            if wanted.isEmpty, person.isEmpty { return true }
            if thread.handles.contains(where: { wanted.contains(ChatHandle.normalize($0)) }) { return true }
            return !person.isEmpty && (thread.names ?? [:]).values.contains { nameMatches($0, person) }
        }
        let matches = export.messages.filter { message in
            guard message.date >= since, let thread = threads[message.threadId], isWanted(thread) else { return false }
            let text = message.text.lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        let limit = min(max(request.limit, 1), ChatSearchRequest.maxLimit)
        let newest = Array(matches.sorted { $0.date > $1.date }.prefix(limit))
        let used = Set(newest.map(\.threadId))
        return ChatSearchResponse(messages: newest, threads: export.threads.filter { used.contains($0.id) })
    }

    /// Every word asked for starts a word of the name: "dana" and "dana o" match "Dana Okafor".
    public static func nameMatches(_ name: String, _ query: String) -> Bool {
        let parts = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let asked = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return !asked.isEmpty && asked.allSatisfy { word in parts.contains { $0.hasPrefix(word) } }
    }

    /// A conversation's latest messages, oldest first.
    public static func thread(_ id: String, in export: ChatExport, limit: Int = 60) -> ChatThreadResponse? {
        guard let thread = export.threads.first(where: { $0.id == id }) else { return nil }
        let messages = export.messages.filter { $0.threadId == id }.sorted { $0.date < $1.date }
        return ChatThreadResponse(thread: thread, messages: Array(messages.suffix(limit)))
    }
}

/// Phone numbers and emails, compared the way Contacts and Messages both write them,
/// and the ids chat networks use where there's no number ("facebook:1000…").
public enum ChatHandle {
    /// "5550100001" for "+1 (555) 010-0001"; emails lowercased; short codes as they are.
    /// A network's id stays whole, so it never passes for a phone number in Contacts.
    public static func normalize(_ handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("@") { return trimmed.lowercased() }
        if network(trimmed) != nil { return trimmed.lowercased() }
        let digits = trimmed.filter(\.isNumber)
        guard !digits.isEmpty else { return trimmed.lowercased() }
        return digits.count > 10 ? String(digits.suffix(10)) : digits
    }

    /// A person, not a business: a full phone number, an email that isn't a no-reply
    /// one, or someone on a chat network (not one of its bots).
    public static func isPerson(_ handle: String) -> Bool {
        if let id = network(handle)?.id { return !id.hasPrefix("bot-") }
        let normalized = normalize(handle)
        if normalized.contains("@") {
            return !["noreply", "no-reply", "donotreply", "do-not-reply", "notifications"].contains { normalized.contains($0) }
        }
        return normalized.count >= 10
    }

    /// "whatsapp:lid-42" is ("whatsapp", "lid-42"); a phone number or an email is nil.
    public static func network(_ handle: String) -> (source: String, id: String)? {
        guard !handle.contains("@"), let colon = handle.firstIndex(of: ":") else { return nil }
        let source = String(handle[..<colon])
        guard !source.isEmpty, source.allSatisfy({ $0.isLetter }) else { return nil }
        return (source, String(handle[handle.index(after: colon)...]))
    }

    /// How to show a handle nobody has a name for: the number, or "Someone on WhatsApp".
    public static func display(_ handle: String) -> String {
        guard let source = network(handle)?.source else { return handle }
        return "Someone on \(ChatSource.label(source))"
    }

    /// The name to show: Contacts', then the network's, then the handle itself.
    public static func name(_ handle: String, contacts: [String: String], in thread: ChatThread?) -> String {
        contacts[normalize(handle)] ?? thread?.names?[handle] ?? display(handle)
    }
}

/// The text inside a Messages `attributedBody`: an NSAttributedString in Apple's
/// old typedstream archive. Recent macOS leaves `message.text` empty and keeps
/// only this. The string follows its class name as `0x84 0x01 0x2B` and a
/// length (one byte; or 0x81 and two bytes, 0x82 and four, little-endian).
public enum TypedStream {
    public static func text(from data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let marker = find(Array("NSString".utf8), in: bytes, from: 0) ?? find(Array("NSMutableString".utf8), in: bytes, from: 0)
        else { return nil }
        guard let plus = find([0x84, 0x01, 0x2B], in: bytes, from: marker), plus - marker < 64 else { return nil }
        var index = plus + 3
        guard index < bytes.count else { return nil }
        var length = 0
        switch bytes[index] {
        case 0x81:
            guard index + 2 < bytes.count else { return nil }
            length = Int(bytes[index + 1]) | Int(bytes[index + 2]) << 8
            index += 3
        case 0x82:
            guard index + 4 < bytes.count else { return nil }
            length = (0..<4).reduce(0) { $0 | Int(bytes[index + 1 + $1]) << (8 * $1) }
            index += 5
        case let byte where byte < 0x80:
            length = Int(byte)
            index += 1
        default:
            return nil
        }
        guard length >= 0, index + length <= bytes.count else { return nil }
        return String(bytes: bytes[index..<index + length], encoding: .utf8)
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count, start <= haystack.count - needle.count else { return nil }
        for index in start...(haystack.count - needle.count) where haystack[index] == needle[0] {
            if Array(haystack[index..<index + needle.count]) == needle { return index }
        }
        return nil
    }
}

extension ChatMessage {
    /// Messages puts U+FFFC where a photo or file sat in the text.
    public static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension AskFormat {
    /// chats_search's result: each text with who sent it, when, and in which conversation.
    /// `names` maps a normalized handle to the contact's name.
    public static func chats(_ found: ChatSearchResponse, names: [String: String], query: String, person: String, fmt: Fmt) -> ToolOutcome {
        let what = [query.isEmpty ? nil : "“\(query)”", person.isEmpty ? nil : "with \(person)"].compactMap { $0 }.joined(separator: " ")
        guard !found.messages.isEmpty else {
            return ToolOutcome(
                text: "No texts match\(what.isEmpty ? "" : " " + what).", trace: "Texts\(what.isEmpty ? "" : " " + what) · none")
        }
        let threads = Dictionary(found.threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var lines = ["\(found.messages.count) text\(found.messages.count == 1 ? "" : "s"), newest first:"]
        for message in found.messages {
            let thread = threads[message.threadId]
            func name(_ handle: String) -> String { ChatHandle.name(handle, contacts: names, in: thread) }
            let conversation = thread.map { $0.name ?? $0.handles.map(name).joined(separator: ", ") } ?? "a conversation"
            let place: String
            if let thread, thread.source != ChatSource.iMessage {
                place = "\(thread.service)\(thread.isGroup ? " group " : " with ")\(conversation)"
            } else {
                place = "\(thread?.isGroup == true ? "the group " : "")\(conversation)"
            }
            let who = message.fromMe ? "The owner" : message.sender.map(name) ?? "Someone"
            let attachment = message.hasAttachment ? " [with a photo or file]" : ""
            let when = "\(fmt.shortDay(message.date)), \(fmt.time(message.date))"
            lines.append("[\(when)] \(who), in \(place): \(message.text)\(attachment)")
        }
        return ToolOutcome(
            text: lines.joined(separator: "\n"),
            trace: "Texts\(what.isEmpty ? "" : " " + what) · \(found.messages.count) found")
    }
}

/// Where `hearth-messages` leaves its work for the relay (the relay's data directory),
/// and where the relay keeps what it read from the bridges, beside it.
public enum ChatFiles {
    public static let export = "messages.json"
    public static let status = "messages-status.json"
    public static let bridgedExport = "bridges.json"
    /// `[ChatSourceStatus]`, one per bridge.
    public static let bridgedStatus = "bridges-status.json"
}
