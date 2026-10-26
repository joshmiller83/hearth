import Executor
import Fluent
import Foundation
import HearthKit
import Jobs
import Logging
import RelayCore
import Vapor

/// How the relay reaches Google. Live: gmailkit as a child process. Tests: fakes.
public struct GoogleAccess: Sendable {
    public var reader: any GoogleReader
    public var writer: any GoogleWriter
    /// The live bridge, so the relay can start it at boot and stop it at shutdown.
    public var bridge: GmailkitBridge?

    public init(reader: any GoogleReader, writer: any GoogleWriter, bridge: GmailkitBridge? = nil) {
        self.reader = reader
        self.writer = writer
        self.bridge = bridge
    }

    public static func live(config: RelayConfig, logger: Logger) -> GoogleAccess {
        let bridge = GmailkitBridge(logger: logger, now: config.now, launch: GmailkitBridge.processLauncher(config: config, logger: logger))
        return GoogleAccess(reader: GmailkitReader(bridge: bridge), writer: GmailkitWriter(bridge: bridge), bridge: bridge)
    }
}

/// Everything the routes, jobs and commands share.
public struct RelayServices: Sendable {
    public var config: RelayConfig
    public var household: Household
    public var google: GoogleAccess
    public var executor: ActionExecutor
    public var jobs: JobRunner
    public var refresher: CalendarRefresher
    public var claude: ClaudeClient?
    /// Push, when an APNs key is installed.
    public var apns: APNsClient?
}

extension Application {
    private struct ServicesKey: StorageKey { typealias Value = RelayServices }
    private struct LimiterKey: StorageKey { typealias Value = FailedAuthLimiter }

    public var relay: RelayServices {
        get {
            guard let services = storage[ServicesKey.self] else { fatalError("configure(_:config:) hasn't run") }
            return services
        }
        set { storage[ServicesKey.self] = newValue }
    }

    var failedAuth: FailedAuthLimiter {
        get {
            guard let limiter = storage[LimiterKey.self] else { fatalError("configure(_:config:) hasn't run") }
            return limiter
        }
        set { storage[LimiterKey.self] = newValue }
    }

    /// The relay's idea of now. Tests move it.
    var now: Date { relay.config.now() }

    /// What a job gets: the database, read-only Google, the household, the clock.
    public func jobContext() -> JobContext {
        JobContext(
            db: db, google: relay.google.reader, household: relay.household, now: relay.config.now,
            logger: logger, claude: relay.claude)
    }
}

extension Request {
    var now: Date { application.now }
    var relay: RelayServices { application.relay }
}
