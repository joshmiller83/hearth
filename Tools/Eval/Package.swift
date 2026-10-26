// swift-tools-version: 6.0
// `make eval`: live checks of Hearth's prompts against the Claude API, on
// synthetic inputs only (fictional notes, flyers drawn on the spot). macOS only
// (it draws with AppKit), never in CI; each run costs a few cents.
import PackageDescription

let package = Package(
    name: "HearthEval",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/HearthKit")],
    targets: [
        .executableTarget(
            name: "hearth-eval",
            dependencies: [
                .product(name: "HearthKit", package: "HearthKit"),
                .product(name: "HearthKitTestSupport", package: "HearthKit"),
            ]
        )
    ]
)
