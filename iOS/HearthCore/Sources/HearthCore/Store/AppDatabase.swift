import Foundation
import GRDB
import HearthKit

/// Hearth's local SQLite database: the last snapshot of everything the relay
/// sent (so the app opens instantly and works offline), captures, rules,
/// people notes and actions waiting to be sent.
///
/// It lives in the App Group container so the widgets and the share extension
/// can read and write it, protected `completeUntilFirstUserAuthentication` so a
/// StandBy widget can read it at night while the phone stays locked.
public final class AppDatabase: Sendable {
    public static let fileName = "Hearth.sqlite"

    public let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// `<App Group>/Database`, or `Application Support/Database` without one (tests).
    public static func directory(
        appGroup: String?,
        containerURL: (String) -> URL? = { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    ) -> URL {
        if let appGroup, let group = containerURL(appGroup) {
            return group.appendingPathComponent("Database", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Hearth/Database", isDirectory: true)
    }

    /// Opens (creating and migrating if needed) the database in `directory`.
    public static func open(directory: URL) throws -> AppDatabase {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protectionAttributes)
        let url = directory.appendingPathComponent(fileName)
        let pool = try DatabasePool(path: url.path, configuration: configuration())
        try migrator.migrate(pool)
        applyProtection(to: [directory, url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")])
        return AppDatabase(writer: pool)
    }

    /// A private in-memory database, for tests and fixture runs.
    public static func inMemory() throws -> AppDatabase {
        let queue = try DatabaseQueue(configuration: configuration())
        try migrator.migrate(queue)
        return AppDatabase(writer: queue)
    }

    /// Let go of the database before iOS suspends the app. The file sits in a shared
    /// container, and iOS kills an app suspended while holding a lock on one
    /// (0xdead10cc). Writes until `resume()` fail with SQLITE_ABORT.
    public static func suspend() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    public static func resume() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }

    static func configuration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        config.observesSuspensionNotifications = true
        return config
    }

    private static var protectionAttributes: [FileAttributeKey: Any]? {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        nil
        #endif
    }

    private static func applyProtection(to urls: [URL]) {
        #if os(iOS)
        let fm = FileManager.default
        for url in urls where fm.fileExists(atPath: url.path) {
            try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        }
        #endif
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            // Snapshots and settings, as JSON under a name.
            try db.execute(
                sql: """
                    CREATE TABLE kv (
                        key TEXT PRIMARY KEY NOT NULL,
                        value BLOB NOT NULL,
                        updatedAt DOUBLE NOT NULL
                    );
                    """)
        }
        migrator.registerMigration("v2-captures") { db in
            // Every capture Claude read: what it was, what it found, what was added (for Undo).
            try db.execute(
                sql: """
                    CREATE TABLE captures (
                        id TEXT PRIMARY KEY NOT NULL,
                        source TEXT NOT NULL,
                        createdAt DOUBLE NOT NULL,
                        updatedAt DOUBLE NOT NULL,
                        status TEXT NOT NULL,
                        summary TEXT NOT NULL,
                        reading BLOB,
                        addedEvents TEXT NOT NULL DEFAULT '[]',
                        addedReminders TEXT NOT NULL DEFAULT '[]',
                        thumbnail BLOB
                    );
                    CREATE INDEX captures_recent ON captures (createdAt);
                    """)
        }
        return migrator
    }

    // MARK: Key-value snapshots

    /// Stores `value` as JSON under `key`.
    public func save(_ value: some Encodable, key: String, now: Date = Date()) throws {
        let data = try HearthJSON.encode(value)
        try writer.write { db in
            try db.execute(
                sql:
                    "INSERT INTO kv (key, value, updatedAt) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt",
                arguments: [key, data, now.timeIntervalSince1970])
        }
    }

    /// The value stored under `key`, if any and if it still decodes.
    public func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = try? writer.read({ db in try Data.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key]) })
        else { return nil }
        return try? HearthJSON.decode(T.self, from: data)
    }

    public func updatedAt(key: String) -> Date? {
        (try? writer.read { db in try Double.fetchOne(db, sql: "SELECT updatedAt FROM kv WHERE key = ?", arguments: [key]) })
            .flatMap { $0 }.map { Date(timeIntervalSince1970: $0) }
    }

    public func remove(key: String) throws {
        try writer.write { db in try db.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [key]) }
    }
}

/// The keys the app stores snapshots under.
public enum StoreKey {
    public static let googleEvents = "relay.events"
    public static let health = "relay.health"
    public static let rules = "house.rules"
    public static let appleCalendars = "apple.calendars"
}

/// A capture as stored: what it was, what Claude read, and what got added.
public struct CaptureRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public enum Status: String, Codable, Sendable {
        /// Claude read it; the owner hasn't added it yet.
        case read
        case added
        /// Added, then taken back within the undo window.
        case undone
        case failed
    }

    public static let databaseTableName = "captures"

    public var id: String
    public var source: String
    public var createdAt: Date
    public var updatedAt: Date
    public var status: Status
    public var summary: String
    public var reading: Data?
    public var addedEvents: String
    public var addedReminders: String
    public var thumbnail: Data?

    public init(
        id: String, source: String, createdAt: Date, status: Status, summary: String, reading: CaptureReading?,
        thumbnail: Data? = nil
    ) {
        self.id = id
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.status = status
        self.summary = summary
        self.reading = reading.flatMap { try? HearthJSON.encode($0) }
        self.addedEvents = "[]"
        self.addedReminders = "[]"
        self.thumbnail = thumbnail
    }

    public var decodedReading: CaptureReading? {
        reading.flatMap { try? HearthJSON.decode(CaptureReading.self, from: $0) }
    }

    public var eventIds: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(addedEvents.utf8))) ?? [] }
        set { addedEvents = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8), as: UTF8.self) }
    }

    public var reminderIds: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(addedReminders.utf8))) ?? [] }
        set { addedReminders = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8), as: UTF8.self) }
    }
}

extension AppDatabase {
    public func save(_ record: CaptureRecord) throws {
        try writer.write { db in try record.save(db) }
    }

    /// The newest captures first.
    public func recentCaptures(limit: Int = 10) -> [CaptureRecord] {
        (try? writer.read { db in try CaptureRecord.order(Column("createdAt").desc).limit(limit).fetchAll(db) }) ?? []
    }

    public func capture(id: String) -> CaptureRecord? {
        try? writer.read { db in try CaptureRecord.fetchOne(db, key: id) }
    }
}
