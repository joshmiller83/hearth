// swift-tools-version: 6.0
// HearthCore is everything in the app that isn't a view: credentials, the relay
// client, the local store, EventKit, the Claude service, the view models and the
// StandBy widgets' snapshot. It builds for macOS too, so all of it is tested with
// `swift test` and no simulator (CI does exactly that).
import PackageDescription

let package = Package(
    name: "HearthCore",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "HearthCore", targets: ["HearthCore"])
    ],
    dependencies: [
        .package(path: "../../Packages/HearthKit"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "HearthCore",
            dependencies: [
                .product(name: "HearthKit", package: "HearthKit"),
                // Fictional data for the app's fixture mode (UI tests, previews).
                .product(name: "HearthKitTestSupport", package: "HearthKit"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "HearthCoreTests", dependencies: ["HearthCore"], resources: [.copy("capture-paper-calendar.json")]),
    ]
)
