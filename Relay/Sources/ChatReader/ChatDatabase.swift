import Foundation
import HearthKit
import Logging
import NIOCore
import SQLiteNIO

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Reads the Mac's Messages database (`~/Library/Messages/chat.db`) into a
/// `ChatExport`. Read only, by SQLite's own `mode=ro`: nothing is ever written
/// to it. Reactions, edits and system rows ("named the conversation") are left
/// out; photos and files are noted, not read.
public enum ChatDatabase {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// macOS refused: the reader needs Full Disk Access.
        case noAccess
        case missing(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .noAccess: "Hearth's Messages helper needs Full Disk Access to read your texts."
            case .missing(let path): "There's no Messages database at \(path). Is Messages signed in on this Mac?"
            case .unreadable(let detail): "Couldn't read the Messages database: \(detail)"
            }
        }
    }

    public static var defaultPath: String {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Messages/chat.db").path
    }

    /// Messages counts time in nanoseconds since 2001 (seconds, before macOS 10.13).
    static func date(_ raw: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: raw > 100_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw))
    }

    /// Fails with `.noAccess` when macOS won't let this process open the file (no Full Disk Access).
    public static func checkAccess(_ path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd < 0 else {
            close(fd)
            return
        }
        switch errno {
        case EPERM, EACCES: throw Failure.noAccess
        case ENOENT: throw Failure.missing(path)
        default: throw Failure.unreadable(String(cString: strerror(errno)))
        }
    }

    /// The last `days` of conversations, at most `limit` messages (the newest).
    public static func read(path: String = defaultPath, days: Int, limit: Int, now: Date) async throws -> ChatExport {
        try checkAccess(path)
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let connection: SQLiteConnection
        do {
            connection = try await SQLiteConnection.open(
                storage: .file(path: "file:\(encoded)?mode=ro"), logger: Logger(label: "hearth-messages"))
        } catch {
            throw Failure.unreadable(String(describing: error))
        }
        do {
            let export = try await read(connection, days: days, limit: limit, now: now)
            try await connection.close()
            return export
        } catch {
            try? await connection.close()
            throw (error as? Failure) ?? Failure.unreadable(String(describing: error))
        }
    }

    static func read(_ db: SQLiteConnection, days: Int, limit: Int, now: Date) async throws -> ChatExport {
        let since = now.addingTimeInterval(-Double(days) * 86400)
        let nanos = Int64(since.timeIntervalSinceReferenceDate * 1_000_000_000)
        let seconds = Int64(since.timeIntervalSinceReferenceDate)
        let rows = try await db.query(
            """
            SELECT m.guid AS guid, m.text AS text, m.attributedBody AS body, m.is_from_me AS from_me, m.date AS date,
                   h.id AS sender, m.cache_has_attachments AS attachments, j.chat_id AS chat
            FROM message m
            JOIN chat_message_join j ON j.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE (m.date >= ?1 OR (m.date < 100000000000 AND m.date >= ?2))
              AND m.associated_message_type = 0 AND m.item_type = 0
            ORDER BY m.date DESC
            LIMIT ?3
            """,
            [.integer(.init(nanos)), .integer(.init(seconds)), .integer(.init(limit))])

        let chats = try await db.query("SELECT ROWID AS id, guid, display_name AS name, service_name AS service FROM chat")
        let members = try await db.query(
            "SELECT j.chat_id AS chat, h.id AS handle FROM chat_handle_join j JOIN handle h ON h.ROWID = j.handle_id")

        var guids: [Int64: String] = [:]
        var threads: [Int64: ChatThread] = [:]
        for row in chats {
            guard let id = row.column("id")?.integer, let guid = row.column("guid")?.string else { continue }
            let name = row.column("name")?.string.flatMap { $0.isEmpty ? nil : $0 }
            guids[Int64(id)] = guid
            threads[Int64(id)] = ChatThread(
                id: guid, name: name, handles: [], service: row.column("service")?.string ?? "iMessage")
        }
        for row in members {
            guard let chat = row.column("chat")?.integer, let handle = row.column("handle")?.string else { continue }
            if !(threads[Int64(chat)]?.handles.contains(handle) ?? true) { threads[Int64(chat)]?.handles.append(handle) }
        }

        var messages: [ChatMessage] = []
        var used = Set<Int64>()
        for row in rows {
            guard let guid = row.column("guid")?.string, let chat = row.column("chat")?.integer.map(Int64.init),
                let thread = guids[chat], let raw = row.column("date")?.integer
            else { continue }
            let plain = row.column("text")?.string ?? ""
            let archived = row.column("body")?.blob.flatMap { TypedStream.text(from: Data($0.readableBytesView)) } ?? ""
            let original = plain.isEmpty ? archived : plain
            let text = ChatMessage.clean(original)
            let attachment = (row.column("attachments")?.integer ?? 0) != 0 || original.contains("\u{FFFC}")
            guard !text.isEmpty || attachment else { continue }
            let fromMe = (row.column("from_me")?.integer ?? 0) != 0
            messages.append(
                ChatMessage(
                    id: guid, threadId: thread, fromMe: fromMe, sender: fromMe ? nil : row.column("sender")?.string,
                    date: date(Int64(raw)), text: text, hasAttachment: attachment))
            used.insert(chat)
        }
        return ChatExport(
            exportedAt: now, since: since, threads: used.sorted().compactMap { threads[$0] }, messages: messages.reversed())
    }
}

/// Writes what the relay reads: the export and how the run went, readable by the owner only.
public enum ChatExportWriter {
    public static func write(_ export: ChatExport, to directory: String) throws {
        try save(HearthJSON.encode(export), to: directory, name: ChatFiles.export)
    }

    public static func write(_ status: ChatSourceStatus, to directory: String) throws {
        try save(HearthJSON.encode(status), to: directory, name: ChatFiles.status)
    }

    static func save(_ data: Data, to directory: String, name: String) throws {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
