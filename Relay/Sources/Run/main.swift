import App
import Foundation
import Logging
import RelayCore
import Vapor

var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)

// One event loop means one SQLite connection; see `configure`.
let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let app = try await Application.make(env, .shared(eventLoopGroup))

var config = RelayConfig.fromEnvironment(ProcessInfo.processInfo.environment)
config.runJobs = RelayConfig.isServeCommand(env.arguments)
if config.commit == nil {
    // deploy/build.sh writes the commit next to the binary.
    let version = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("VERSION")
    config.commit = (try? String(contentsOf: version, encoding: .utf8))?.split(separator: "\n").first.map(String.init)
}

do {
    try await configure(app, config: config)
    try await app.execute()
} catch {
    app.logger.report(error: error)
    try? await app.asyncShutdown()
    try? await eventLoopGroup.shutdownGracefully()
    exit(1)
}
try await app.asyncShutdown()
try await eventLoopGroup.shutdownGracefully()
