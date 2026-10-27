import Foundation
import HearthKit
import Observation

/// What the app is built from, once per launch: live (Keychain, the App Group
/// database, EventKit, the real relay) or fixtures (UI tests and previews).
public struct AppServices: Sendable {
    public var secrets: any SecretStore
    public var database: AppDatabase
    public var calendar: any AppleCalendar
    /// Contacts, for Ask's people_get.
    public var people: any PeopleDirectory
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
        people: any PeopleDirectory = NoPeople(),
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
        self.people = people
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
    /// The mail sorting rules (Hearth's defaults until the owner changes one).
    public private(set) var mailRules: [MailRule]
    public private(set) var credentialsVersion = 0
    /// Today's morning brief, when the relay has written one.
    public private(set) var brief: Brief?
    /// The kind idea the owner set aside today.
    public var kindIdeaDismissed = false

    public let plans: PlansModel
    public let sources: SourcesModel
    public let capture: CaptureModel
    public let inbox: InboxModel
    public let ask: AskModel
    public let signals: SignalsModel
    public let people: PeopleModel

    public init(services: AppServices) {
        self.services = services
        health = services.database.load(HealthResponse.self, key: StoreKey.health)
        rules = services.database.load(HouseRules.self, key: StoreKey.rules) ?? HouseRules()
        mailRules = services.database.load([MailRule].self, key: StoreKey.mailRules) ?? MailRules.defaults
        brief = services.database.load(Brief.self, key: StoreKey.brief)
        plans = PlansModel(services: services)
        sources = SourcesModel(services: services)
        capture = CaptureModel(services: services, inbox: services.inbox)
        inbox = InboxModel(services: services)
        ask = AskModel(services: services)
        signals = SignalsModel(services: services)
        people = PeopleModel(services: services)
        plans.app = self
        sources.app = self
        capture.app = self
        inbox.app = self
        ask.app = self
        signals.app = self
        people.app = self
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

    /// Turns one mail rule on or off; the relay sorts with it from the next sweep.
    public func setMailRule(_ id: String, enabled: Bool) {
        guard let index = mailRules.firstIndex(where: { $0.id == id }) else { return }
        mailRules[index].enabled = enabled
        try? services.database.save(mailRules, key: StoreKey.mailRules, now: now)
        Task { await uploadContext() }
    }

    /// How much of what's in the inboxes now a rule catches (the preview beside its switch).
    public func mailRuleMatches(_ rule: MailRule) -> Int {
        guard let items = inbox.snapshot?.items else { return 0 }
        return items.filter { rule.match.matches($0.item, labelNames: [:], now: now) }.count
    }

    /// Tells the relay the owner's switches, mail rules and the Apple calendars it can't see.
    public func uploadContext() async {
        guard let relay else { return }
        let apple = plans.appleEvents.filter { $0.start < now.addingTimeInterval(14 * 86400) }
        let custom = services.database.load([MailRule].self, key: StoreKey.mailRules)
        try? await relay.uploadContext(PhoneContext(rules: rules, appleEvents: apple, mailRules: custom, uploadedAt: now))
    }

    /// Everything the app shows, fresh: health first (it carries the household), then plans.
    public func refreshAll(force: Bool = false) async {
        await refreshHealth()
        await plans.refresh(force: force)
        await inbox.refresh(force: force)
        await signals.refresh()
        await refreshBrief()
        plans.publishWidgets()
    }

    /// Today's brief; yesterday's doesn't count.
    public var todaysBrief: Brief? {
        guard let brief, brief.day == RFC3339.day(now, zone: household.zone) else { return nil }
        return brief
    }

    public func refreshBrief() async {
        guard let relay, let fresh = try? await relay.brief() else { return }
        brief = fresh
        try? services.database.save(fresh, key: StoreKey.brief, now: now)
    }

    /// Hands the phone's APNs token to the relay.
    public func registerForPush(token: Data, environment: String) async {
        let hex = token.map { byte in
            let digits = Array("0123456789abcdef")
            return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
        }.joined()
        try? await relay?.registerDevice(DeviceRegistration(token: hex, environment: environment))
    }
}
