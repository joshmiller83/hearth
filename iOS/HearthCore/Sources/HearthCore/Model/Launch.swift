import Foundation
import HearthKit
import HearthKitTestSupport

#if canImport(WidgetKit)
import WidgetKit
#endif

/// Writes the widgets' snapshot to the App Group and asks WidgetKit to redraw.
public struct WidgetCenterPublisher: WidgetPublishing {
    public let file: WidgetSnapshotFile

    public init(file: WidgetSnapshotFile) {
        self.file = file
    }

    public func publish(_ snapshot: WidgetSnapshot) {
        try? file.write(snapshot)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

extension AppServices {
    /// The real thing: Keychain, the App Group database, EventKit, the relay over HTTPS.
    public static func live(appGroup: String?, keychainGroup: String?) throws -> AppServices {
        let directory = AppDatabase.directory(appGroup: appGroup)
        let transport = URLSessionTransport()
        return AppServices(
            secrets: KeychainSecretStore(accessGroup: keychainGroup),
            database: try AppDatabase.open(directory: directory),
            calendar: EventKitCalendar(),
            makeRelay: { RelayClient(credentials: $0, transport: transport) },
            makeClaude: { ClaudeClient(apiKey: $0, transport: transport) },
            widgets: WidgetCenterPublisher(file: WidgetSnapshotFile(directory: directory))
        )
    }

    /// The fictional Rivera household on the design's Monday, offline: for UI
    /// tests, previews and screenshots. Actions "succeed" instantly.
    public static func fixtures(now: Date = Fixtures.now, waits: Bool = true) -> AppServices {
        let relay = FixtureRelay()
        let wait: @Sendable (TimeInterval) async -> Void
        if waits {
            wait = { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        } else {
            wait = { _ in }
        }
        return AppServices(
            secrets: MemorySecretStore([.relayURL: "https://relay.example", .relayKey: "hrk_fixture"]),
            database: try! AppDatabase.inMemory(),
            calendar: FixtureCalendar(),
            clock: ManualClock(now),
            makeRelay: { _ in relay },
            makeClaude: { ClaudeClient(apiKey: $0, transport: ScriptedTransport([])) },
            wait: wait
        )
    }
}

/// A relay that answers from the fixtures.
public actor FixtureRelay: RelayAPI {
    private var sent: [ApprovedAction] = []

    public init() {}

    public var submitted: [ApprovedAction] { sent }

    public func health() async throws -> HealthResponse {
        HealthResponse(
            status: "ok", version: "fixture", commit: "fixture", now: Fixtures.now,
            gmailkit: BridgeStatus(state: .up, since: Fixtures.now), accounts: Fixtures.accounts, household: Fixtures.household,
            jobs: [
                JobStatus(
                    name: "calendar", lastRun: Fixtures.now.addingTimeInterval(-6 * 60),
                    lastSuccess: Fixtures.now.addingTimeInterval(-6 * 60))
            ],
            claude: true, push: false)
    }

    public func events(from: Date, to: Date, refresh: Bool) async throws -> EventsResponse {
        let google = Fixtures.week.filter { if case .google = $0.source { return true } else { return false } }
        let calendars = Fixtures.accounts.map { CalendarInfo(id: "primary", account: $0.alias, name: $0.name, isPrimary: true) }
        return EventsResponse(events: google, calendars: calendars, fetchedAt: Fixtures.now.addingTimeInterval(-6 * 60))
    }

    public func submit(_ actions: [ApprovedAction]) async throws -> [ActionStatus] {
        sent.append(contentsOf: actions)
        return actions.map { ActionStatus(id: $0.id, kind: $0.kind, state: .done, updatedAt: Fixtures.now) }
    }

    public func statuses(ids: [String]) async throws -> [ActionStatus] {
        sent.filter { ids.contains($0.id) }.map { ActionStatus(id: $0.id, kind: $0.kind, state: .done, updatedAt: Fixtures.now) }
    }

    public func cancel(id: String) async throws -> ActionStatus {
        guard let action = sent.first(where: { $0.id == id }) else { throw RelayError.http(status: 404, reason: "No such action.") }
        return ActionStatus(id: id, kind: action.kind, state: .cancelled, updatedAt: Fixtures.now)
    }

    public func uploadContext(_ context: PhoneContext) async throws {}
}

/// Apple calendars from the fixtures.
public struct FixtureCalendar: AppleCalendar {
    public init() {}

    public func access() -> CalendarAccess { .full }
    public func requestAccess() async -> CalendarAccess { .full }

    public func calendars() async -> [AppleCalendarInfo] {
        [
            AppleCalendarInfo(id: "family", title: "Family", source: "iCloud", isICloud: true),
            AppleCalendarInfo(id: "birthdays", title: "Birthdays", source: "Other", isICloud: false, isBirthdays: true),
        ]
    }

    public func events(from: Date, to: Date, calendarIds: Set<String>?) async -> [AgendaEvent] {
        Fixtures.week.filter { $0.source.isApple && $0.start < to && $0.end >= from }
    }

    public func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}
