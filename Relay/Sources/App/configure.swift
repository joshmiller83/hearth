import Executor
import Fluent
import FluentSQLiteDriver
import Foundation
import HearthKit
import Jobs
import RelayCore
import Vapor

public enum RelayInfo {
    public static let version = "0.1.0"
}

/// Sets up the database, Google access, the jobs, middleware and routes.
///
/// Like the tree farm server, the relay runs one event loop and so one SQLite
/// connection: every write happens alone.
public func configure(_ app: Application, config: RelayConfig, google: GoogleAccess? = nil, claude: ClaudeClient? = nil) async throws {
    app.http.server.configuration.hostname = config.host
    app.http.server.configuration.port = config.port
    app.routes.defaultMaxBodySize = "4mb"

    switch config.database {
    case .memory:
        app.databases.use(.sqlite(.memory), as: .sqlite)
    case .file(let path):
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: Paths.parent(path)), withIntermediateDirectories: true)
        app.databases.use(.sqlite(.file(path)), as: .sqlite)
    }
    app.migrations.add(CreateSchema())
    app.migrations.add(CreateMailTriage())
    try await app.autoMigrate()

    let household = try config.loadHousehold()
    let access = google ?? .live(config: config, logger: app.logger)
    let claude =
        claude
        ?? config.loadAnthropicKey().map {
            ClaudeClient(apiKey: $0, transport: VaporHTTPTransport(client: app.client))
        }
    let db = app.db
    let executor = ActionExecutor(
        db: db,
        writer: access.writer,
        settings: {
            let context = try? await Cache(db: db).get(PhoneContext.self, Cache.context)
            return ActionExecutor.Settings(household: household, rules: context?.rules ?? HouseRules())
        },
        now: config.now,
        logger: app.logger
    )
    app.relay = RelayServices(
        config: config,
        household: household,
        google: access,
        executor: executor,
        jobs: JobRunner(jobs: [CalendarCacheJob(), MailSweepJob()]),
        refresher: CalendarRefresher(),
        claude: claude
    )

    app.failedAuth = FailedAuthLimiter()

    app.middleware = Middlewares()
    app.middleware.use(RouteLoggingMiddleware(logLevel: .info))
    app.middleware.use(APIErrorMiddleware())

    app.asyncCommands.use(IssueKeyCommand(), as: "issue-key")
    app.asyncCommands.use(PairCommand(), as: "pair")
    app.asyncCommands.use(ListKeysCommand(), as: "list-keys")
    app.asyncCommands.use(RevokeKeyCommand(), as: "revoke-key")
    app.asyncCommands.use(BackupCommand(), as: "backup")
    app.asyncCommands.use(RunJobCommand(), as: "run-job")

    if let bridge = access.bridge {
        app.lifecycle.use(BridgeLifecycle(bridge: bridge, warmUp: config.runJobs))
    }
    if config.runJobs {
        // The jobs tick every 30 seconds; each decides whether it's due.
        app.lifecycle.use(
            Ticker(name: "jobs", every: 30, initialDelay: 5) { app in
                await app.relay.jobs.tick(app.jobContext())
            })
        app.lifecycle.use(
            Ticker(name: "actions", every: 30, initialDelay: 10) { app in
                await app.relay.executor.runDue()
            })
        app.lifecycle.use(BackupScheduler())
    }

    try routes(app)
}

func routes(_ app: Application) throws {
    try app.register(collection: HealthController())
    let keyed = app.grouped(RelayKeyMiddleware())
    try keyed.register(collection: CalendarController())
    try keyed.register(collection: ActionsController())
    try keyed.register(collection: ContextController())
    try keyed.register(collection: MailController())
}
