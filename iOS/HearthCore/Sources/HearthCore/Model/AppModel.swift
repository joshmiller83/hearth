import Foundation
import HearthKit
import Observation

/// What the app is built from, once per launch: live (Keychain, the App Group
/// database, EventKit, the real relay) or fixtures (UI tests and previews).
public struct AppServices: Sendable {
    public var secrets: any SecretStore
    public var database: AppDatabase
    public var calendar: any AppleCalendar
    public var clock: any HearthClock
    /// Builds the relay client once credentials exist.
    public var makeRelay: @Sendable (RelayCredentials) -> any RelayAPI
    /// Builds a Claude client from the key in Sources.
    public var makeClaude: @Sendable (String) -> ClaudeClient
    public var widgets: any WidgetPublishing
    /// Where the share extension leaves things for the app.
    public var inbox: SharedInbox?
    /// How undo windows wait. Tests pass one that returns at once.
    public var wait: @Sendable (TimeInterval) async -> Void

    public init(
        secrets: any SecretStore,
        database: AppDatabase,
        calendar: any AppleCalendar,
        clock: any HearthClock = SystemClock(),
        makeRelay: @escaping @Sendable (RelayCredentials) -> any RelayAPI,
        makeClaude: @escaping @Sendable (String) -> ClaudeClient,
        widgets: any WidgetPublishing = NoWidgets(),
        inbox: SharedInbox? = nil,
        wait: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.secrets = secrets
        self.database = database
        self.calendar = calendar
        self.clock = clock
        self.makeRelay = makeRelay
        self.makeClaude = makeClaude
        self.widgets = widgets
        self.inbox = inbox
        self.wait = wait
    }
}

/// The root of the app's state: the relay connection, the household it
/// describes, the owner's switches, and the screen models.
@MainActor
@Observable
public final class AppModel {
    public let services: AppServices
    public private(set) var health: HealthResponse?
    public private(set) var relayProblem: String?
    public private(set) var rules: HouseRules
    public private(set) var credentialsVersion = 0

    public let plans: PlansModel
    public let sources: SourcesModel
    public let capture: CaptureModel

    public init(services: AppServices) {
        self.services = services
        health = services.database.load(HealthResponse.self, key: StoreKey.health)
        rules = services.database.load(HouseRules.self, key: StoreKey.rules) ?? HouseRules()
        plans = PlansModel(services: services)
        sources = SourcesModel(services: services)
        capture = CaptureModel(services: services, inbox: services.inbox)
        plans.app = self
        sources.app = self
        capture.app = self
    }

    public var now: Date { services.clock.now }

    /// The relay, once its address and key are in Sources.
    public var relay: (any RelayAPI)? {
        _ = credentialsVersion
        return RelayCredentials.load(from: services.secrets).map(services.makeRelay)
    }

    public var claude: ClaudeClient? {
        _ = credentialsVersion
        return services.secrets.read(.claudeKey).flatMap { $0.isEmpty ? nil : services.makeClaude($0) }
    }

    public var isConfigured: Bool { relay != nil }

    public var household: Household { health?.household ?? .placeholder }

    /// Call after Sources saves new credentials.
    func credentialsChanged() {
        credentialsVersion += 1
    }

    /// Asks the relay how it is; keeps the last good answer when it can't be reached.
    @discardableResult
    public func refreshHealth() async -> HealthResponse? {
        guard let relay else {
            relayProblem = RelayError.notConfigured.description
            return nil
        }
        do {
            let answer = try await relay.health()
            health = answer
            relayProblem = nil
            try? services.database.save(answer, key: StoreKey.health, now: now)
            return answer
        } catch {
            relayProblem = (error as? RelayError)?.description ?? String(describing: error)
            return nil
        }
    }

    public func setRules(_ new: HouseRules) {
        var new = new
        new.askBeforeActing = true  // always on: the relay only runs approved actions
        rules = new
        try? services.database.save(new, key: StoreKey.rules, now: now)
        Task { await uploadContext() }
    }

    /// Tells the relay the owner's switches and the Apple calendars it can't see.
    public func uploadContext() async {
        guard let relay else { return }
        let apple = plans.appleEvents.filter { $0.start < now.addingTimeInterval(14 * 86400) }
        try? await relay.uploadContext(PhoneContext(rules: rules, appleEvents: apple, uploadedAt: now))
    }

    /// Everything the app shows, fresh: health first (it carries the household), then plans.
    public func refreshAll(force: Bool = false) async {
        await refreshHealth()
        await plans.refresh(force: force)
    }
}
