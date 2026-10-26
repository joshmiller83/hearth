import Foundation
import HearthCore

/// How this launch gets its data.
enum LaunchMode: Equatable {
    /// The Keychain, the App Group database, EventKit and the real relay.
    case live
    /// The fictional household on the design's Monday, offline (UI tests, screenshots).
    case fixtures

    static let fixturesArgument = "-UITestFixtures"

    static func current(arguments: [String] = ProcessInfo.processInfo.arguments) -> LaunchMode {
        arguments.contains(fixturesArgument) ? .fixtures : .live
    }

    /// True when this process hosts unit tests: never prompt for permissions then.
    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

@MainActor
enum AppEnvironment {
    static func makeModel(mode: LaunchMode = .current()) -> AppModel {
        switch mode {
        case .fixtures:
            return AppModel(services: .fixtures())
        case .live:
            if LaunchMode.isTestHost { return AppModel(services: .fixtures()) }
            let info = Bundle.main.infoDictionary ?? [:]
            let appGroup = info["HearthAppGroup"] as? String
            // Unsigned builds (CI, some simulators) have no keychain group entitlement.
            let keychainGroup = (info["HearthKeychainGroup"] as? String).flatMap { $0.hasPrefix("$(") ? nil : $0 }
            do {
                return AppModel(services: try .live(appGroup: appGroup, keychainGroup: keychainGroup))
            } catch {
                // Never quietly run on a throwaway database; fixtures make the problem obvious.
                return AppModel(services: .fixtures())
            }
        }
    }
}
