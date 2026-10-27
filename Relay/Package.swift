// swift-tools-version: 6.0
// hearth-relay: the always-on half of Hearth, on the iMac behind the Cloudflare
// tunnel. Vapor 4 + Fluent on SQLite. It holds what a phone can't: Google access
// (through gmailkit), the clock (sweeps, the brief), push, and the executor that
// runs actions the owner approved.
//
// The targets draw one line on purpose: `Jobs` (everything that runs on a timer)
// cannot see `Executor` (everything that writes to mail or calendars). Only
// `App` wires both, and only the approved-actions route reaches the executor.
// `DependencyGraphTests` keeps it that way.
//
// `hearth-messages` is the one exception to "the relay does it": a tiny helper
// that launchd runs as the owner every two minutes. It alone reads the Mac's
// Messages database (it alone needs Full Disk Access) and leaves an export the
// relay serves. It reaches nothing but that file.
import PackageDescription

let package = Package(
    name: "HearthRelay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Run", targets: ["Run"]),
        .executable(name: "hearth-messages", targets: ["MessagesExport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.122.2"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/sqlite-nio.git", from: "1.13.2"),
        .package(path: "../Packages/HearthKit"),
    ],
    targets: [
        .target(
            name: "RelayCore",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "HearthKit", package: "HearthKit"),
            ]
        ),
        .target(name: "Jobs", dependencies: ["RelayCore"]),
        .target(name: "Executor", dependencies: ["RelayCore"]),
        .target(
            name: "App",
            dependencies: [
                "RelayCore", "Jobs", "Executor",
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
            ]
        ),
        .executableTarget(name: "Run", dependencies: ["App"]),
        .target(
            name: "ChatReader",
            dependencies: [
                .product(name: "SQLiteNIO", package: "sqlite-nio"),
                .product(name: "HearthKit", package: "HearthKit"),
            ]
        ),
        .executableTarget(name: "MessagesExport", dependencies: ["ChatReader"]),
        .testTarget(
            name: "AppTests",
            dependencies: [
                "App", "RelayCore", "Jobs", "Executor", "ChatReader",
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "HearthKitTestSupport", package: "HearthKit"),
            ]
        ),
    ]
)
