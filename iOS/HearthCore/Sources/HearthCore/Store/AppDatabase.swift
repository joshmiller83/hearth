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
