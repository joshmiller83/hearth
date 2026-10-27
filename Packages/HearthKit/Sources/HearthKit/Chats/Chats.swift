import Foundation

// Text conversations. Today that's iMessage and SMS, read from the Mac's
// Messages database by `hearth-messages`; the shapes leave room for other chat
// sources. Read only: Hearth never sends a text.

/// One conversation.
public struct ChatThread: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Where it came from: "imessage".
    public var source: String
    /// A named group's name.
    public var name: String?
    /// The other people in it: phone numbers or emails, as the source has them.
    public var handles: [String]
    /// "iMessage", "SMS", "RCS".
    public var service: String

    public init(id: String, source: String = ChatSource.iMessage, name: String? = nil, handles: [String], service: String = "iMessage") {
        self.id = id
        self.source = source
        self.name = name
        self.handles = handles
        self.service = service
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
}

/// Whether the source can be read, as of the helper's last run.
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

    public init(
        state: State, checkedAt: Date? = nil, exportedAt: Date? = nil, threads: Int = 0, messages: Int = 0, message: String? = nil
    ) {
        self.state = state
        self.checkedAt = checkedAt
        self.exportedAt = exportedAt
        self.threads = threads
        self.messages = messages
        self.message = message
    }

    public static let notInstalled = ChatSourceStatus(state: .notInstalled)
}

/// A conversation as the phone lists it: its last message, and whether it's waiting on the owner.
public struct ChatSummary: Codable, Hashable, Sendable, Identifiable {
    public var thread: ChatThread
    public var last: ChatMessage
    /// Their messages since the owner last wrote, oldest first (up to five).
    public var unanswered: [ChatMessage]
    /// They asked something the owner hasn't answered, and the owner has texted them in the
    /// export's window: a stranger's question (an offer, a wrong number) waits on no one.
    public var waiting: Bool
    /// They asked (`Chats.asks`), whoever they are. The phone counts these as waiting too
    /// when the sender is in its Contacts.
    public var asked: Bool

    public init(thread: ChatThread, last: ChatMessage, unanswered: [ChatMessage], waiting: Bool, asked: Bool) {
        self.thread = thread
        self.last = last
        self.unanswered = unanswered
        self.waiting = waiting
        self.asked = asked
    }

    public var id: String { thread.id }
    /// Changes when they write again, so leaving one out lasts until the next message.
    public var waitingId: String { thread.id + "#" + last.id }
}

/// `GET /v1/chats`.
public struct ChatsResponse: Codable, Hashable, Sendable {
    public var status: ChatSourceStatus
    /// Most recent first.
    public var threads: [ChatSummary]

    public init(status: ChatSourceStatus, threads: [ChatSummary]) {
        self.status = status
        self.threads = threads
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

    public init(query: String, handles: [String] = [], days: Int = 30, limit: Int = 20) {
        self.query = query
        self.handles = handles
        self.days = days
        self.limit = limit
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
        // Everyone the owner has written to in the window, in any conversation: Messages
        // keeps one person's SMS and iMessage apart, and a group counts too.
        let texted = Set(
            export.threads.filter { byThread[$0.id]?.contains(where: \.fromMe) == true }.flatMap(\.handles).map(ChatHandle.normalize))
        var out: [ChatSummary] = []
        for thread in export.threads {
            guard let messages = byThread[thread.id]?.sorted(by: { $0.date < $1.date }), let last = messages.last else { continue }
            let unanswered = Array(messages.reversed().prefix { !$0.fromMe }.reversed())
            let asked = asks(thread: thread, unanswered: unanswered, ownerName: ownerName, now: now)
            let known = thread.handles.contains { texted.contains(ChatHandle.normalize($0)) }
            out.append(
                ChatSummary(
                    thread: thread, last: last, unanswered: Array(unanswered.suffix(5)), waiting: asked && known, asked: asked))
        }
        return Array(out.sorted { $0.last.date > $1.last.date }.prefix(limit))
    }

    /// They asked and the owner hasn't written since: a question in their latest run of
    /// messages, in the last three days, from a person (not a short code or a no-reply
    /// address). In a group, only when it also names the owner. It waits on the owner
    /// only when they know the sender (`summaries`, and Contacts on the phone).
    public static func asks(thread: ChatThread, unanswered: [ChatMessage], ownerName: String, now: Date) -> Bool {
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
        let threads = Dictionary(export.threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let matches = export.messages.filter { message in
            guard message.date >= since, let thread = threads[message.threadId] else { return false }
            if !wanted.isEmpty, !thread.handles.contains(where: { wanted.contains(ChatHandle.normalize($0)) }) { return false }
            let text = message.text.lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        let limit = min(max(request.limit, 1), ChatSearchRequest.maxLimit)
        let newest = Array(matches.sorted { $0.date > $1.date }.prefix(limit))
        let used = Set(newest.map(\.threadId))
        return ChatSearchResponse(messages: newest, threads: export.threads.filter { used.contains($0.id) })
    }

    /// A conversation's latest messages, oldest first.
    public static func thread(_ id: String, in export: ChatExport, limit: Int = 60) -> ChatThreadResponse? {
        guard let thread = export.threads.first(where: { $0.id == id }) else { return nil }
        let messages = export.messages.filter { $0.threadId == id }.sorted { $0.date < $1.date }
        return ChatThreadResponse(thread: thread, messages: Array(messages.suffix(limit)))
    }
}

/// Phone numbers and emails, compared the way Contacts and Messages both write them.
public enum ChatHandle {
    /// "5550100001" for "+1 (555) 010-0001"; emails lowercased; short codes as they are.
    public static func normalize(_ handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("@") { return trimmed.lowercased() }
        let digits = trimmed.filter(\.isNumber)
        guard !digits.isEmpty else { return trimmed.lowercased() }
        return digits.count > 10 ? String(digits.suffix(10)) : digits
    }

    /// A person, not a business: a full phone number, or an email that isn't a no-reply one.
    public static func isPerson(_ handle: String) -> Bool {
        let normalized = normalize(handle)
        if normalized.contains("@") {
            return !["noreply", "no-reply", "donotreply", "do-not-reply", "notifications"].contains { normalized.contains($0) }
        }
        return normalized.count >= 10
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
        func name(_ handle: String) -> String { names[ChatHandle.normalize(handle)] ?? handle }
        let threads = Dictionary(found.threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var lines = ["\(found.messages.count) text\(found.messages.count == 1 ? "" : "s"), newest first:"]
        for message in found.messages {
            let thread = threads[message.threadId]
            let conversation = thread.map { $0.name ?? $0.handles.map(name).joined(separator: ", ") } ?? "a conversation"
            let who = message.fromMe ? "The owner" : message.sender.map(name) ?? "Someone"
            let attachment = message.hasAttachment ? " [with a photo or file]" : ""
            lines.append(
                "[\(fmt.shortDay(message.date)), \(fmt.time(message.date))] \(who), in \(thread?.isGroup == true ? "the group " : "")\(conversation): \(message.text)\(attachment)"
            )
        }
        return ToolOutcome(
            text: lines.joined(separator: "\n"),
            trace: "Texts\(what.isEmpty ? "" : " " + what) · \(found.messages.count) found")
    }
}

/// Where `hearth-messages` leaves its work for the relay: the relay's data directory.
public enum ChatFiles {
    public static let export = "messages.json"
    public static let status = "messages-status.json"
}
