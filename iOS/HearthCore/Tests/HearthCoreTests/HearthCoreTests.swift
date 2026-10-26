import Foundation
import HearthKit
import HearthKitTestSupport
import Testing

@testable import HearthCore

@Suite("Relay client")
struct RelayClientTests {
    let credentials = RelayCredentials(url: URL(string: "https://relay.example")!, key: "hrk_test")

    @Test func requestsCarryTheKeyAndTheWindow() async throws {
        let body = try HearthJSON.encode(EventsResponse(events: [], calendars: [], fetchedAt: Fixtures.now))
        let transport = ScriptedTransport([.response(HTTPResponse(status: 200, body: body))])
        let client = RelayClient(credentials: credentials, transport: transport)
        _ = try await client.events(from: Fixtures.now, to: Fixtures.now.addingTimeInterval(86400), refresh: true)
        let request = try #require(transport.requests.first)
        #expect(request.headers["authorization"] == "Bearer hrk_test")
        #expect(request.url.path == "/v1/calendar/events")
        let query = request.url.query ?? ""
        #expect(query.contains("from=2026-10-26T14:08:00Z") && query.contains("refresh=1"))
        #expect(request.timeout == 120)
    }

    @Test func errorsBecomeSentences() async throws {
        let transport = ScriptedTransport([
            .response(HTTPResponse(status: 401, body: Data(#"{"error":true,"reason":"This needs the relay key from Sources."}"#.utf8))),
            .response(
                HTTPResponse(
                    status: 503, body: Data(#"{"error":true,"reason":"Couldn't read Google Calendar: gmailkit isn't running"}"#.utf8))),
            .failure("The Internet connection appears to be offline."),
        ])
        let client = RelayClient(credentials: credentials, transport: transport)
        await #expect(throws: RelayError.unauthorized) { try await client.health() }
        await #expect(throws: RelayError.http(status: 503, reason: "Couldn't read Google Calendar: gmailkit isn't running")) {
            try await client.health()
        }
        await #expect(throws: RelayError.self) { try await client.health() }
    }

    @Test func actionsGoAsABatch() async throws {
        let action = ApprovedAction(
            id: "a1", kind: .rsvp(account: "work", calendarId: "primary", eventId: "e", response: .accepted),
            context: .plans, approvedAt: Fixtures.now)
        let reply = try HearthJSON.encode(
            ActionStatuses(actions: [ActionStatus(id: "a1", kind: action.kind, state: .done, updatedAt: Fixtures.now)]))
        let transport = ScriptedTransport([.response(HTTPResponse(status: 200, body: reply))])
        let statuses = try await RelayClient(credentials: credentials, transport: transport).submit([action])
        #expect(statuses.map(\.state) == [.done])
        let sent = try HearthJSON.decode(ActionBatch.self, from: try #require(transport.requests.first?.body))
        #expect(sent.actions == [action])
        #expect(transport.requests.first?.method == "POST")
    }

    @Test(arguments: [
        ("hearth.example.com", "https://hearth.example.com"),
        ("https://hearth.example.com/v1/health?x=1", "https://hearth.example.com"),
        ("  https://hearth.example.com/  ", "https://hearth.example.com"),
        ("http://localhost:8791", "http://localhost:8791"),
    ])
    func relayAddressesAreNormalized(text: String, expected: String) {
        #expect(RelayCredentials.normalize(text)?.absoluteString == expected)
    }

    @Test func plainHTTPToTheInternetIsRefused() {
        #expect(RelayCredentials.normalize("http://hearth.example.com") == nil)
        #expect(RelayCredentials.normalize("") == nil)
    }
}

@Suite("Local store")
struct StoreTests {
    @Test func snapshotsRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let rules = HouseRules(surpriseGuard: false)
        try db.save(rules, key: StoreKey.rules, now: Fixtures.now)
        #expect(db.load(HouseRules.self, key: StoreKey.rules) == rules)
        #expect(db.updatedAt(key: StoreKey.rules) == Fixtures.now)
        try db.remove(key: StoreKey.rules)
        #expect(db.load(HouseRules.self, key: StoreKey.rules) == nil)
    }

    @Test func theWidgetFileRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = WidgetSnapshotFile(directory: dir)
        let snapshot = WidgetSnapshot(
            generatedAt: Fixtures.now, ownerName: "Sam", timeZone: "America/New_York", events: [],
            invitesWaiting: 2, repliesReady: 0, signals: 1)
        try file.write(snapshot)
        #expect(file.read() == snapshot)
        try? FileManager.default.removeItem(at: dir)
    }
}

@Suite("Plans")
@MainActor
struct PlansModelTests {
    func loaded(waits: Bool = false) async -> AppModel {
        let app = AppModel(services: .fixtures(waits: waits))
        await app.refreshAll()
        return app
    }

    @Test func everyCalendarMergesIntoOneAgenda() async {
        let app = await loaded()
        let plans = app.plans
        #expect(plans.phase == .loaded)
        #expect(
            plans.dayEvents.map { plans.rowTitle($0) } == [
                "Coffee chat, agency lead", "Lunch with Robin", "Module weekly sync", "Cover the plants, frost tonight",
                "Robin is busy: book club",
            ])
        #expect(plans.week.map(\.mark) == [.plans, .plans, .invite, .invite, .none, .plans, .plans])
        #expect(app.household.ownerName == "Sam")
    }

    @Test func invitesShowTheirConflictAndWhoGetsTheReply() async throws {
        let app = await loaded()
        let plans = app.plans
        #expect(plans.invites.map(\.title) == ["Alumni mixer", "Leaders huddle"])
        let huddle = try #require(plans.invites.last)
        #expect(plans.when(huddle) == "Thu, Oct 29 · 7:00–8:00 PM")
        #expect(plans.agenda.conflictSentence(for: huddle) == "Overlaps Bible study, 7:00–8:30 PM on Small group")
        #expect(plans.inviteMeta(huddle) == "Landed on work@ · from organizer")
        #expect(plans.inviteStatus(huddle) == "Your reply emails organizer.")
    }

    @Test func anAnswerWaitsFiveSecondsThenGoesToTheRelay() async throws {
        let services = AppServices.fixtures(waits: false)
        let app = AppModel(services: services)
        await app.refreshAll()
        let plans = app.plans
        let huddle = try #require(plans.invites.last)
        plans.reply(to: huddle, .tentative)
        #expect(plans.inviteStatus(huddle) == "Sending Maybe in 5 s")
        // Let the undo window (instant here) close and the send finish.
        for _ in 0..<20 where plans.replies[huddle.id]?.state != .sent { await Task.yield() }
        #expect(plans.replies[huddle.id]?.state == .sent)
        #expect(plans.inviteStatus(huddle) == "Maybe · organizer gets an email")
        let relay = try #require(app.relay as? FixtureRelay)
        let sent = await relay.submitted
        #expect(sent.map(\.kind) == [.rsvp(account: "work", calendarId: "primary", eventId: "huddle", response: .tentative)])
        #expect(sent.first?.context == .plans)
        // The answered invite now counts as an answer in the agenda.
        #expect(plans.agenda.waitingOnMe(now: app.now).map(\.title) == ["Alumni mixer"])
    }

    @Test func undoInsideTheWindowSendsNothing() async throws {
        let app = await loaded()
        let plans = app.plans
        let mixer = try #require(plans.invites.first)
        plans.reply(to: mixer, .declined)
        plans.undoReply(to: mixer)
        for _ in 0..<20 { await Task.yield() }
        #expect(plans.replies[mixer.id] == nil)
        let relay = try #require(app.relay as? FixtureRelay)
        #expect(await relay.submitted.isEmpty)
    }

    @Test func appleEventsCantBeAnsweredThroughGoogle() async throws {
        let app = await loaded()
        let lunch = try #require(app.plans.dayEvents.first { $0.title == "Lunch with Robin" })
        app.plans.reply(to: lunch, .accepted)
        #expect(app.plans.replies.isEmpty)
    }

    @Test func withoutARelayItSaysWhatToDo() async {
        var services = AppServices.fixtures()
        services.secrets = MemorySecretStore()
        let app = AppModel(services: services)
        await app.refreshAll()
        #expect(app.plans.phase == .failed("Add the relay's address and key in Sources."))
        #expect(!app.plans.appleEvents.isEmpty)  // the phone's own calendars still show
    }
}

@Suite("Today")
@MainActor
struct TodayTests {
    @Test func theMorningLooksLikeTheDesign() async {
        let app = AppModel(services: .fixtures())
        await app.refreshAll()
        let today = TodaySummary.make(app: app)
        #expect(today.dateLine == "MONDAY, OCTOBER 26")
        #expect(today.greeting == "Good morning, Sam.")
        #expect(today.nextUp?.title == "Coffee chat, agency lead")
        #expect(today.nextUpLabel == "Next up · in 52 min")
        #expect(today.nextUpMeta == "Zoom · landed on work@")
        #expect(today.needsYou.map(\.title) == ["RSVP: Alumni mixer", "RSVP: Leaders huddle"])
        #expect(today.needsYou.last?.detail == "Thu 7 PM · overlaps Bible study")
        #expect(today.sweepLine == "Checked 6 accounts and every calendar at 10:02 AM. 2 things need you.")
        #expect(today.comingUp.map(\.title) == ["Jordan's birthday", "Bible study", "Trunk or Treat", "Neighborhood brunch"])
    }
}

@Suite("Sources")
@MainActor
struct SourcesTests {
    @Test func savingTheRelayChecksIt() async {
        var services = AppServices.fixtures()
        services.secrets = MemorySecretStore()
        let app = AppModel(services: services)
        #expect(!app.isConfigured)
        app.sources.relayURLText = "relay.example/"
        app.sources.relayKeyText = " hrk_new "
        await app.sources.saveRelay()
        #expect(services.secrets.read(.relayURL) == "https://relay.example")
        #expect(services.secrets.read(.relayKey) == "hrk_new")
        #expect(app.sources.relayKeyText.isEmpty)
        #expect(app.sources.relayCheck == .ok("Connected · gmailkit up · 6 accounts"))
        #expect(app.isConfigured)
    }

    @Test func aBadAddressIsCaughtBeforeSaving() async {
        var services = AppServices.fixtures()
        services.secrets = MemorySecretStore()
        let app = AppModel(services: services)
        app.sources.relayURLText = "http://not-secure.example"
        await app.sources.saveRelay()
        #expect(app.sources.relayCheck == .failed("That doesn't look like the relay's https address."))
        #expect(services.secrets.read(.relayURL) == nil)
    }

    @Test func claudeKeysAreCheckedForShape() async {
        let app = AppModel(services: .fixtures())
        app.sources.claudeKeyText = "not-a-key"
        await app.sources.saveClaudeKey()
        #expect(app.sources.claudeCheck == .failed("Claude keys start with sk-ant-."))
    }

    @Test func askBeforeActingStaysOn() {
        let app = AppModel(services: .fixtures())
        app.setRules(HouseRules(askBeforeActing: false, surpriseGuard: false))
        #expect(app.rules.askBeforeActing)
        #expect(!app.rules.surpriseGuard)
    }
}

@Suite("StandBy widget snapshot")
@MainActor
struct WidgetSnapshotTests {
    func snapshot(extra: [AgendaEvent] = []) -> WidgetSnapshot {
        let agenda = Agenda(events: Fixtures.week + extra, household: Fixtures.household)
        return WidgetSnapshot.make(agenda: agenda, now: Fixtures.now, fetchedAt: Fixtures.now)
    }

    @Test func nextUpAndTodayFollowTheClock() throws {
        let s = snapshot()
        #expect(s.nextUp(at: Fixtures.now)?.title == "Coffee chat, agency lead")
        #expect(s.nextUp(at: Fixtures.at("2026-10-26T11:31"))?.title == "Lunch with Robin")
        // The partner's evening isn't "next up", but it's on today's list as busy.
        #expect(s.today(at: Fixtures.at("2026-10-26T17:45")).map(\.title) == ["Robin is busy: book club"])
        #expect(s.invitesWaiting == 2)
        #expect(s.topNeed == "RSVP: Alumni mixer")
        #expect(s.events.first { $0.title == "Coffee chat, agency lead" }?.hasCall == true)
    }

    @Test func redrawsAtEveryBoundary() {
        let moments = snapshot().boundaries(after: Fixtures.now)
        #expect(moments.first == Fixtures.at("2026-10-26T11:00"))
        #expect(moments.contains(Fixtures.at("2026-10-26T20:00")))
        #expect(moments == moments.sorted())
    }

    @Test func surprisePlansStayPrivateOnTheNightstand() {
        var dinner = Fixtures.google("surprise", "Dinner at the Thai place", "2026-10-26T19:00", "2026-10-26T21:00")
        dinner.notes = SurpriseMarker.notes("Reservation for two")
        let s = snapshot(extra: [dinner])
        #expect(s.events.contains { $0.title == "Private" })
        #expect(!s.events.contains { $0.title.contains("Thai") })
        #expect(SurpriseMarker.notes("Reservation for two") == "Reservation for two\n\n#hearth-surprise")
    }
}
