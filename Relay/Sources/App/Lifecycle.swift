import Foundation
import RelayCore
import SQLKit
import Vapor

/// Runs `work` every `every` seconds while the relay serves.
final class Ticker: LifecycleHandler, @unchecked Sendable {
    let name: String
    let every: TimeInterval
    let initialDelay: TimeInterval
    let work: @Sendable (Application) async -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(name: String, every: TimeInterval, initialDelay: TimeInterval = 0, work: @escaping @Sendable (Application) async -> Void) {
        self.name = name
        self.every = every
        self.initialDelay = initialDelay
        self.work = work
    }

    func didBootAsync(_ app: Application) async throws {
        let every = self.every
        let delay = self.initialDelay
        let work = self.work
        let job = Task { [weak app] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            while !Task.isCancelled {
                guard let app else { return }
                await work(app)
                try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
            }
        }
        setTask(job)
    }

    func shutdownAsync(_ app: Application) async {
        let job = currentTask()
        job?.cancel()
        await job?.value
    }

    private func setTask(_ job: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        task = job
    }

    private func currentTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }
}

/// Starts gmailkit at boot (so the first request doesn't wait) and stops it at shutdown.
struct BridgeLifecycle: LifecycleHandler {
    let bridge: GmailkitBridge
    let warmUp: Bool

    func didBootAsync(_ app: Application) async throws {
        guard warmUp else { return }
        let bridge = self.bridge
        Task { await bridge.warmUp() }
    }

    func shutdownAsync(_ app: Application) async {
        await bridge.shutdown()
    }
}

/// `VACUUM INTO` copies of the database, named `hearth-YYYYMMDD-HHMMSS.sqlite`
/// in local time, keeping the newest `backupsKept`.
enum Backups {
    static let pattern = #"^hearth-\d{8}-\d{6}(-\d+)?\.sqlite$"#

    @discardableResult
    static func run(app: Application) async throws -> URL {
        let dir = URL(fileURLWithPath: app.relay.config.backupDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = stampText(app.now)
        var url = dir.appendingPathComponent("hearth-\(stamp).sqlite")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("hearth-\(stamp)-\(n).sqlite")
            n += 1
        }
        guard let sql = app.db as? any SQLDatabase else { throw CommandFailure("The database can't be backed up.") }
        try await sql.raw("VACUUM INTO \(bind: url.path)").run()
        try prune(dir, keep: app.relay.config.backupsKept)
        return url
    }

    static func prune(_ dir: URL, keep: Int) throws {
        for name in try backupNames(in: dir).dropLast(max(keep, 1)) {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    static func backupNames(in dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.range(of: pattern, options: .regularExpression) != nil }
            .sorted()
    }

    static func newest(in dir: URL) -> Date? {
        (try? backupNames(in: dir))?.last.flatMap { name in
            (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.modificationDate] as? Date
        }
    }

    static func stampText(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: date)
        func pad(_ v: Int?, _ w: Int) -> String {
            let s = String(v ?? 0)
            return String(repeating: "0", count: max(0, w - s.count)) + s
        }
        return pad(c.year, 4) + pad(c.month, 2) + pad(c.day, 2) + "-" + pad(c.hour, 2) + pad(c.minute, 2) + pad(c.second, 2)
    }
}

/// A safety net behind the nightly launchd backup: every hour, back up if the
/// newest copy is more than 25 hours old.
final class BackupScheduler: LifecycleHandler, @unchecked Sendable {
    static let maxAge: TimeInterval = 25 * 3600
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    static func isDue(newest: Date?, now: Date) -> Bool {
        guard let newest else { return true }
        return now.timeIntervalSince(newest) >= maxAge
    }

    func didBootAsync(_ app: Application) async throws {
        let dir = URL(fileURLWithPath: app.relay.config.backupDirectory, isDirectory: true)
        let job = Task { [weak app] in
            while !Task.isCancelled {
                guard let app else { return }
                if Self.isDue(newest: Backups.newest(in: dir), now: Date()) {
                    do {
                        let url = try await Backups.run(app: app)
                        app.logger.info("Backed up to \(url.path)")
                    } catch {
                        app.logger.error("Backup failed: \(String(reflecting: error))")
                    }
                }
                try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
            }
        }
        setTask(job)
    }

    func shutdownAsync(_ app: Application) async {
        let job = currentTask()
        job?.cancel()
        await job?.value
    }

    private func setTask(_ job: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        task = job
    }

    private func currentTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }
}

/// A command's failure: its message is printed and `Run` exits non-zero.
struct CommandFailure: Error, CustomStringConvertible, LocalizedError {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}
