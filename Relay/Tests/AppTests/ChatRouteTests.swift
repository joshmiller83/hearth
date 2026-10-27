import ChatReader
import Foundation
import HearthKit
import HearthKitTestSupport
import Logging
import SQLiteNIO
import Testing
import Vapor

@testable import App

/// A made-up Messages database with the tables and columns the reader uses.
func makeMessagesDatabase(at path: String, now: Date) async throws {
    let db = try await SQLiteConnection.open(storage: .file(path: path), logger: Logger(label: "test"))
    for sql in [
        "CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT)",
        "CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, display_name TEXT, service_name TEXT)",
        "CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER)",
        "CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER)",
        """
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB, handle_id INTEGER,
          is_from_me INTEGER, date INTEGER, associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0,
          cache_has_attachments INTEGER DEFAULT 0)
        """,
        "INSERT INTO handle VALUES (1, '+15550100001', 'iMessage'), (2, '+15550100003', 'iMessage'), (3, 'lou.rivera@example.com', 'iMessage')",
        "INSERT INTO chat VALUES (1, 'iMessage;-;+15550100001', '', 'iMessage'), (2, 'iMessage;+;chat42', 'Rivera cousins', 'iMessage')",
        "INSERT INTO chat_handle_join VALUES (1, 1), (2, 2), (2, 3)",
    ] {
        _ = try await db.query(sql)
    }
    func nanos(_ minutesAgo: Double) -> SQLiteData {
        .integer(.init(now.addingTimeInterval(-minutesAgo * 60).timeIntervalSinceReferenceDate * 1_000_000_000))
    }
    let archived = Data(
        base64Encoded:
            "BAtzdHJlYW10eXBlZIHoA4QBQISEhBJOU0F0dHJpYnV0ZWRTdHJpbmcAhIQITlNPYmplY3QAhZKEhIQITlNTdHJpbmcBlIQBKxdDYW4geW91IGdyYWIgbWlsaz8g8J+lm4aEAmlJARWShISEDE5TRGljdGlvbmFyeQCUhAFpAIaG"
    )!
    // id, guid, text, body, handle, from me, minutes ago, reaction type, item type, attachments, chat
    typealias Row = (Int, String, String?, Data?, Int, Int, Double, Int, Int, Int, Int)
    let rows: [Row] = [
        (1, "g-old", "Too old to export", nil, 1, 0, 70 * 24 * 60, 0, 0, 0, 1),
        (2, "g-me", "Heading over", nil, 1, 1, 90, 0, 0, 0, 1),
        (3, "g-body", nil, archived, 1, 0, 30, 0, 0, 0, 1),
        (4, "g-tapback", "Loved “Heading over”", nil, 1, 0, 29, 2000, 0, 0, 1),
        (5, "g-photo", "\u{FFFC}", nil, 1, 0, 28, 0, 0, 1, 1),
        (6, "g-renamed", nil, nil, 2, 0, 20, 0, 2, 0, 2),
        (7, "g-group", "Sam, can you bring chairs?", nil, 3, 0, 10, 0, 0, 0, 2),
    ]
    func int(_ value: Int) -> SQLiteData { .integer(.init(value)) }
    for row in rows {
        let binds: [SQLiteData] = [
            int(row.0), .text(row.1), row.2.map { .text($0) } ?? .null, row.3.map { .blob(ByteBuffer(bytes: $0)) } ?? .null,
            int(row.4), int(row.5), nanos(row.6), int(row.7), int(row.8), int(row.9),
        ]
        _ = try await db.query(
            """
            INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, is_from_me, date, associated_message_type,
              item_type, cache_has_attachments) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, binds)
        _ = try await db.query("INSERT INTO chat_message_join VALUES (?, ?, 0)", [int(row.10), int(row.0)])
    }
    try await db.close()
}

@Suite("Texts")
struct ChatRouteTests {
    static func directory() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-chats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test func theReaderExportsConversationsAndLeavesTheRestOut() async throws {
        let dir = try Self.directory()
        let path = dir + "/chat.db"
        try await makeMessagesDatabase(at: path, now: Fixtures.now)
        let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        let export = try await ChatDatabase.read(path: path, days: 60, limit: 100, now: Fixtures.now)
        #expect(export.messages.map(\.id) == ["g-me", "g-body", "g-photo", "g-group"])
        #expect(export.messages[0].fromMe && export.messages[0].sender == nil)
        #expect(export.messages[1].text == "Can you grab milk? 🥛")
        #expect(export.messages[1].sender == "+15550100001")
        #expect(export.messages[2].hasAttachment && export.messages[2].text.isEmpty)
        #expect(export.threads.map(\.id) == ["iMessage;-;+15550100001", "iMessage;+;chat42"])
        #expect(export.threads[0].name == nil)
        #expect(export.threads[1].name == "Rivera cousins")
        #expect(export.threads[1].handles == ["+15550100003", "lou.rivera@example.com"])
        // Read only: the database file is untouched.
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date == before)
        let newest = try await ChatDatabase.read(path: path, days: 60, limit: 2, now: Fixtures.now)
        #expect(newest.messages.map(\.id) == ["g-photo", "g-group"])
        await #expect(throws: ChatDatabase.Failure.missing(dir + "/nope.db")) {
            try await ChatDatabase.read(path: dir + "/nope.db", days: 60, limit: 10, now: Fixtures.now)
        }
    }

    @Test func theRelayServesWhatTheHelperExported() async throws {
        let dir = try Self.directory()
        try ChatExportWriter.write(Fixtures.chats, to: dir)
        try ChatExportWriter.write(
            ChatSourceStatus(state: .ok, checkedAt: Fixtures.now, exportedAt: Fixtures.now, threads: 5, messages: 9), to: dir)
        try await withTestApp(adjust: { $0.chatsDirectory = dir }) { t in
            let key = try await t.key()
            let list = try await t.app.client2.send(.GET, RelayPath.chats, key: key).decode(ChatsResponse.self)
            #expect(list.status.state == .ok)
            #expect(list.threads.filter(\.waiting).map(\.thread.id) == ["mom"])
            let thread = try await t.app.client2.send(.GET, RelayPath.chatThread + "?id=mom", key: key).decode(ChatThreadResponse.self)
            #expect(thread.messages.map(\.id) == ["m1", "m2", "m3"])
            let missing = try await t.app.client2.send(.GET, RelayPath.chatThread + "?id=nobody", key: key)
            #expect(missing.status == .notFound)
            let found = try await t.app.client2.send(
                .POST, RelayPath.tools + "/chats_search", key: key, json: ChatSearchRequest(query: "roast", days: 30)
            ).decode(ChatSearchResponse.self)
            #expect(found.messages.map(\.id) == ["m2"])
            let health = try await t.app.client2.send(.GET, RelayPath.health, key: key).decode(HealthResponse.self)
            #expect(health.chats?.state == .ok)
            let noKey = try await t.app.client2.send(.GET, RelayPath.chats)
            #expect(noKey.status == .unauthorized)

            // The helper went quiet: nothing is served as if it were current.
            t.clock.advance(20 * 60)
            let stale = try await t.app.client2.send(.GET, RelayPath.chats, key: key).decode(ChatsResponse.self)
            #expect(stale.status.state == .notRunning)
            #expect(stale.threads.isEmpty)
            let search = try await t.app.client2.send(
                .POST, RelayPath.tools + "/chats_search", key: key, json: ChatSearchRequest(query: "roast"))
            #expect(search.status == .serviceUnavailable)
        }
    }

    @Test func withoutTheHelperThereAreNoTexts() async throws {
        let dir = try Self.directory()
        try await withTestApp(adjust: { $0.chatsDirectory = dir }) { t in
            let key = try await t.key()
            let list = try await t.app.client2.send(.GET, RelayPath.chats, key: key).decode(ChatsResponse.self)
            #expect(list.status == .notInstalled)
            try ChatExportWriter.write(
                ChatSourceStatus(state: .needsAccess, checkedAt: t.clock.now, message: "needs Full Disk Access"), to: dir)
            let blocked = try await t.app.client2.send(.GET, RelayPath.chats, key: key).decode(ChatsResponse.self)
            #expect(blocked.status.state == .needsAccess)
            #expect(blocked.threads.isEmpty)
        }
    }
}
