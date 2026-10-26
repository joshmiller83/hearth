// swift-tools-version: 6.0
// HearthKit holds everything the app and the relay agree on: the domain model,
// the agenda merge, the mail rules, the trust policies, the relay's API and the
// Claude client. It depends only on Foundation and builds on macOS, iOS and
// Linux, so the rules are tested once (in CI, on Linux) and used everywhere.
import PackageDescription

let package = Package(
    name: "HearthKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HearthKit", targets: ["HearthKit"]),
        // Fictional people, mail and calendars for tests, previews and UI-test runs.
        // Test targets and the app's fixture mode link it; nothing real lives in it.
        .library(name: "HearthKitTestSupport", targets: ["HearthKitTestSupport"]),
    ],
    targets: [
        .target(name: "HearthKit"),
        .target(name: "HearthKitTestSupport", dependencies: ["HearthKit"]),
        .testTarget(
            name: "HearthKitTests",
            dependencies: ["HearthKit", "HearthKitTestSupport"],
            resources: [.copy("Recorded")]
        ),
    ]
)
