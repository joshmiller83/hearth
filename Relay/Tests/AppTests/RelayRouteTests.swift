import Foundation
import HearthKit
import HearthKitTestSupport
import NIOCore
import RelayCore
import Testing
import Vapor

@testable import App

@Suite("Health, keys and errors")
struct HealthAndAuthTests {
    @Test func healthWithoutAKeySaysOnlyOK() async throws {
        try await withTestApp { t in
            let res = try await t.app.client2.send(.GET, RelayPath.health)
            #expect(res.status == .ok)
            let body = try res.decode(HealthResponse.self)
            #expect(body.status == "ok")
            #expect(body.accounts == nil && body.household == nil && body.gmailkit == nil)
        }
    }

    @Test func healthWithTheKeyShowsTheAccountsAndJobs() async throws {
        try await withTestApp { t in
            let res = try await t.app.client2.send(.GET, RelayPath.health, key: try await t.key())
            let body = try res.decode(HealthResponse.self)
            #expect(body.gmailkit?.state == .up)
            #expect(body.accounts?.count == Fixtures.accounts.count)
            #expect(body.household?.partnerName == "Robin")
            #expect(body.jobs?.map(\.name) == ["calendar", "mail", "brief", "weather"])
            #expect(body.claude == false)
        }
    }

    @Test func routesNeedTheKey() async throws {
        try await withTestApp { t in
            let none = try await t.app.client2.send(.GET, RelayPath.calendarEvents)
            #expect(none.status == .unauthorized)
            #expect(none.errorReason == "This needs the relay key from Sources.")
            let wrong = try await t.app.client2.send(.GET, RelayPath.calendarEvents, key: "hrk_nope")
            #expect(wrong.status == .unauthorized)
            let right = try await t.app.client2.send(.GET, RelayPath.calendarEvents, key: try await t.key())
            #expect(right.status == .ok)
        }
    }

    @Test func manyWrongKeysLockTheAddressOut() async throws {
        try await withTestApp { t in
            let good = try await t.key()
            for _ in 0..<10 {
                _ = try await t.app.client2.send(.GET, RelayPath.calendarEvents, key: "hrk_wrong")
            }
            let locked = try await t.app.client2.send(.GET, RelayPath.calendarEvents, key: good)
            #expect(locked.status == .tooManyRequests)
            #expect(locked.headers.first(name: "Retry-After") != nil)
            t.clock.advance(16 * 60)
            #expect(try await t.app.client2.send(.GET, RelayPath.calendarEvents, key: good).status == .ok)
        }
    }

    @Test func revokedKeysStopWorking() async throws {
        try await withTestApp { t in
            let key = try await t.key()
            let model = try #require(try await RelayKeyModel.query(on: t.app.db).first())
            model.revokedAt = t.clock.now
            try await model.update(on: t.app.db)
            #expect(try await t.app.client2.send(.GET, RelayPath.calendarEvents, key: key).status == .unauthorized)
        }
    }

    @Test func onlyTheKeysHashIsStored() async throws {
        try await withTestApp { t in
            let key = try await t.key()
            #expect(key.hasPrefix("hrk_") && key.count > 40)
            let model = try #require(try await RelayKeyModel.query(on: t.app.db).first())
            #expect(model.hash == Codes.sha256Hex(key))
            #expect(model.hash != key)
        }
    }

    @Test func unknownRoutesAnswerWithAJSONError() async throws {
        try await withTestApp { t in
            let res = try await t.app.client2.send(.GET, "/v1/nope")
            #expect(res.status == .notFound)
            #expect(try res.decode(APIErrorBody.self).error)
        }
    }

    @Test func unexpectedErrorsDontLeakDetails() async throws {
        try await withTestApp { t in
            t.app.get("boom") { _ -> String in
                struct Secret: Error { let detail = "token and secrets" }
                throw Secret()
            }
            let res = try await t.app.client2.send(.GET, "/boom")
            #expect(res.status == .internalServerError)
            #expect(!res.text.contains("secrets"))
            #expect(res.errorReason == "Something went wrong on the relay.")
        }
    }

    @Test func cloudflaresAddressIsBelievedOnlyFromLocalhost() throws {
        let headers: HTTPHeaders = ["CF-Connecting-IP": "203.0.113.9"]
        #expect(ClientIP.resolve(peer: try SocketAddress(ipAddress: "127.0.0.1", port: 1), headers: headers) == "203.0.113.9")
        #expect(ClientIP.resolve(peer: try SocketAddress(ipAddress: "192.0.2.4", port: 1), headers: headers) == "192.0.2.4")
    }

    @Test func configReadsTheEnvironment() {
        let config = RelayConfig.fromEnvironment([
            "HEARTH_PORT": "9001", "HEARTH_DB": "/tmp/h/hearth.sqlite", "HEARTH_GMAILKIT_DIR": "/srv/gmail",
            "HEARTH_HOUSEHOLD": "/tmp/h/household.json", "HOME": "/Users/test",
        ])
        #expect(config.port == 9001)
        #expect(config.database == .file("/tmp/h/hearth.sqlite"))
        #expect(config.backupDirectory == "/tmp/h/backups")
        #expect(config.python == "/srv/gmail/.venv/bin/python")
        #expect(config.householdFile == "/tmp/h/household.json")
        #expect(RelayConfig().port == 8791)
        #expect(RelayConfig.isServeCommand(["Run"]) && RelayConfig.isServeCommand(["Run", "serve"]))
        #expect(!RelayConfig.isServeCommand(["Run", "issue-key"]))
        #expect(Paths.expandTilde("~/x", home: "/Users/test") == "/Users/test/x")
    }
}

@Suite("Calendar cache")
struct CalendarRouteTests {
    @Test func theFirstRequestSweepsThenTheCacheAnswers() async throws {
        try await withTestApp { t in
            let key = try await t.key()
            let res = try await t.app.client2.send(.GET, RelayPath.calendarEvents, key: key)
            #expect(res.status == .ok)
            let body = try res.decode(EventsResponse.self)
            #expect(body.events.map(\.title) == ["Leaders huddle", "book club"])  // December is outside the default window
            #expect(body.problems == [SourceProblem(source: "kid", message: "[kid.rivera@example.com] invalid_grant")])
            #expect(body.calendars.count == 2)
            _ = try await t.app.client2.send(.GET, RelayPath.calendarEvents, key: key)
            #expect(t.google.eventSweeps == 1)
            _ = try await t.app.client2.send(.GET, RelayPath.calendarEvents + "?refresh=1", key: key)
            #expect(t.google.eventSweeps == 2)
        }
    }

    @Test func thePartnersEventsLeaveTheRelayBusyOnly() async throws {
        try await withTestApp { t in
            let body = try await t.app.client2.send(.GET, RelayPath.calendarEvents, key: try await t.key()).decode(EventsResponse.self)
            let book = try #require(body.events.first { $0.title == "book club" })
            #expect(book.busyOnly)
            #expect(book.location == nil)
            #expect(!body.events.contains { $0.location == "Library" })
        }
    }

    @Test func theWindowFollowsFromAndTo() async throws {
        try await withTestApp { t in
            let path = RelayPath.calendarEvents + "?from=2026-12-01T00:00:00Z&to=2027-01-01T00:00:00Z"
            let body = try await t.app.client2.send(.GET, path, key: try await t.key()).decode(EventsResponse.self)
            #expect(body.events.map(\.title) == ["Far future"])
            let bad = try await t.app.client2.send(.GET, RelayPath.calendarEvents + "?from=yesterday", key: try await t.key())
            #expect(bad.status == .badRequest)
        }
    }

    @Test func whenGoogleIsDownTheLastSweepIsServed() async throws {
        try await withTestApp { t in
            let key = try await t.key()
            _ = try await t.app.client2.send(.GET, RelayPath.calendarEvents, key: key)
            t.google.failReads = BridgeError.notRunning("gmailkit exited")
            let body = try await t.app.client2.send(.GET, RelayPath.calendarEvents + "?refresh=1", key: key).decode(EventsResponse.self)
            #expect(body.events.count == 2)
            #expect(body.problems.contains { $0.source == "relay" })
        }
    }

    @Test func withNoCacheAndNoGoogleItSaysSo() async throws {
        let google = FakeGoogle()
        google.failReads = BridgeError.notRunning("gmailkit exited")
        try await withTestApp(google: google) { t in
            let res = try await t.app.client2.send(.GET, RelayPath.calendarEvents, key: try await t.key())
            #expect(res.status == .serviceUnavailable)
            #expect(res.errorReason?.contains("gmailkit") == true)
        }
    }
}

@Suite("Approved actions")
struct ActionRouteTests {
    func batch(_ actions: ApprovedAction...) -> ActionBatch { ActionBatch(actions: actions) }

    @Test func anRSVPRunsOnceAndUpdatesTheCache() async throws {
        try await withTestApp { t in
            let key = try await t.key()
            _ = try await t.app.client2.send(.GET, RelayPath.calendarEvents, key: key)
            let rsvp = ApprovedAction(
                id: "rsvp-1", kind: .rsvp(account: "work", calendarId: "primary", eventId: "huddle", response: .tentative),
                context: .plans, approvedAt: t.clock.now)
            let first = try await t.app.client2.send(.POST, RelayPath.actions, key: key, json: batch(rsvp)).decode(ActionStatuses.self)
            #expect(first.actions.map(\.state) == [.done])
            #expect(t.google.writes == ["respond work primary huddle tentative"])

            // The same id again (a retry): same answer, nothing runs twice.
            let again = try await t.app.client2.send(.POST, RelayPath.actions, key: key, json: batch(rsvp)).decode(ActionStatuses.self)
            #expect(again.actions.map(\.state) == [.done])
            #expect(t.google.writes.count == 1)

            let events = try await t.app.client2.send(.GET, RelayPath.calendarEvents, key: key).decode(EventsResponse.self)
            #expect(events.events.first { $0.sourceEventId == "huddle" }?.myResponse == .tentative)
        }
    }

    @Test func staleApprovalsAreRefused() async throws {
        try await withTestApp { t in
            let old = ApprovedAction(
                id: "old", kind: .modifyMail(account: "work", messageIds: ["m1"], change: .archive),
                context: .inbox, approvedAt: t.clock.now.addingTimeInterval(-3 * 86400))
            let res = try await t.app.client2.send(.POST, RelayPath.actions, key: try await t.key(), json: batch(old)).decode(
                ActionStatuses.self)
            #expect(res.actions.first?.state == .refused)
            #expect(res.actions.first?.message?.contains("more than a day old") == true)
            #expect(t.google.writes.isEmpty)
        }
    }

    @Test func theSurpriseGuardKeepsPlansOffThePartnersCalendar() async throws {
        try await withTestApp { t in
            let start = Fixtures.at("2026-10-30T19:00")
            let theirs = ApprovedAction(
                id: "s1",
                kind: .createHold(account: "robin", title: "Dinner", start: start, end: start.addingTimeInterval(10800), notes: nil),
                context: .surprise, approvedAt: t.clock.now)
            let mine = ApprovedAction(
                id: "s2",
                kind: .createHold(account: "work", title: "Dinner", start: start, end: start.addingTimeInterval(10800), notes: nil),
                context: .surprise, approvedAt: t.clock.now)
            let res = try await t.app.client2.send(.POST, RelayPath.actions, key: try await t.key(), json: batch(theirs, mine)).decode(
                ActionStatuses.self)
            #expect(res.actions.map(\.state) == [.refused, .done])
            #expect(t.google.writes == ["hold work Dinner 2026-10-30T19:00:00-04:00"])
            #expect(res.actions[1].result?["event_id"]?.stringValue == "hold-1")
        }
    }

    @Test func aScheduledSendWaitsForItsTime() async throws {
        try await withTestApp { t in
            let key = try await t.key()
            let send = ApprovedAction(
                id: "later", kind: .reply(account: "work", messageId: "m9", body: "Tuesday works.", replyAll: false),
                context: .inbox, approvedAt: t.clock.now, notBefore: Fixtures.at("2026-10-27T08:00"))
            let res = try await t.app.client2.send(.POST, RelayPath.actions, key: key, json: batch(send)).decode(ActionStatuses.self)
            #expect(res.actions.first?.state == .pending)
            #expect(await t.app.relay.executor.runDue() == 0)
            #expect(t.google.writes.isEmpty)

            t.clock.set(Fixtures.at("2026-10-27T08:00:30"))
            #expect(await t.app.relay.executor.runDue() == 1)
            #expect(t.google.writes == ["reply work m9 Tuesday works."])
            let status = try await t.app.client2.send(.GET, RelayPath.actions + "?ids=later", key: key).decode(ActionStatuses.self)
            #expect(status.actions.first?.state == .done)
        }
    }

    @Test func aScheduledSendCanBeTakenBackUntilItRuns() async throws {
        try await withTestApp { t in
            let key = try await t.key()
            let send = ApprovedAction(
                id: "undo-me", kind: .reply(account: "work", messageId: "m9", body: "Hi", replyAll: false),
                context: .inbox, approvedAt: t.clock.now, notBefore: t.clock.now.addingTimeInterval(3600))
            _ = try await t.app.client2.send(.POST, RelayPath.actions, key: key, json: batch(send))
            let cancelled = try await t.app.client2.send(.DELETE, RelayPath.actions + "/undo-me", key: key).decode(CancelResponse.self)
            #expect(cancelled.action.state == .cancelled)
            t.clock.advance(7200)
            #expect(await t.app.relay.executor.runDue() == 0)
            #expect(t.google.writes.isEmpty)

            let missing = try await t.app.client2.send(.DELETE, RelayPath.actions + "/nope", key: key)
            #expect(missing.status == .notFound)
        }
    }

    @Test func finishedActionsCantBeCancelled() async throws {
        try await withTestApp { t in
            let key = try await t.key()
            let archive = ApprovedAction(
                id: "done", kind: .modifyMail(account: "work", messageIds: ["a", "b"], change: .archive),
                context: .inbox, approvedAt: t.clock.now)
            _ = try await t.app.client2.send(.POST, RelayPath.actions, key: key, json: batch(archive))
            #expect(t.google.writes == ["modify work a,b Archive"])
            #expect(try await t.app.client2.send(.DELETE, RelayPath.actions + "/done", key: key).status == .conflict)
        }
    }

    @Test func gmailkitRestartingMeansTryAgainNotFail() async throws {
        let google = FakeGoogle()
        google.failWrites = BridgeError.notRunning("starting")
        try await withTestApp(google: google) { t in
            let key = try await t.key()
            let archive = ApprovedAction(
                id: "retry", kind: .modifyMail(account: "work", messageIds: ["a"], change: .trash),
                context: .inbox, approvedAt: t.clock.now)
            let res = try await t.app.client2.send(.POST, RelayPath.actions, key: key, json: batch(archive)).decode(ActionStatuses.self)
            #expect(res.actions.first?.state == .pending)
            #expect(res.actions.first?.message?.contains("try again") == true)

            google.failWrites = nil
            t.clock.advance(150)
            #expect(await t.app.relay.executor.runDue() == 1)
            #expect(google.writes == ["modify work a Move to Trash"])
        }
    }

    @Test func gmailkitRefusingIsAFailureWithItsReason() async throws {
        let google = FakeGoogle()
        google.failWrites = BridgeError.remote("an unknown id fails the whole batch")
        try await withTestApp(google: google) { t in
            let archive = ApprovedAction(
                id: "f", kind: .modifyMail(account: "work", messageIds: ["zzz"], change: .archive),
                context: .inbox, approvedAt: t.clock.now)
            let res = try await t.app.client2.send(.POST, RelayPath.actions, key: try await t.key(), json: batch(archive)).decode(
                ActionStatuses.self)
            #expect(res.actions.first?.state == .failed)
            #expect(res.actions.first?.message == "an unknown id fails the whole batch")
        }
    }

    @Test func emptyAndHugeBatchesAreRejected() async throws {
        try await withTestApp { t in
            let key = try await t.key()
            #expect(try await t.app.client2.send(.POST, RelayPath.actions, key: key, json: ActionBatch(actions: [])).status == .badRequest)
            let many = (0..<51).map {
                ApprovedAction(
                    id: "a\($0)", kind: .modifyMail(account: "work", messageIds: ["m"], change: .markRead),
                    context: .inbox, approvedAt: t.clock.now)
            }
            #expect(
                try await t.app.client2.send(.POST, RelayPath.actions, key: key, json: ActionBatch(actions: many)).status == .badRequest)
        }
    }

    @Test func thePhonesContextReachesTheExecutor() async throws {
        try await withTestApp { t in
            let key = try await t.key()
            var rules = HouseRules()
            rules.surpriseGuard = false
            let upload = try await t.app.client2.send(
                .POST, RelayPath.context, key: key, json: PhoneContext(rules: rules, uploadedAt: t.clock.now))
            #expect(upload.status == .noContent)
            let start = Fixtures.at("2026-10-30T19:00")
            let hold = ApprovedAction(
                id: "g",
                kind: .createHold(account: "robin", title: "Dinner", start: start, end: start.addingTimeInterval(3600), notes: nil),
                context: .surprise, approvedAt: t.clock.now)
            let res = try await t.app.client2.send(.POST, RelayPath.actions, key: key, json: ActionBatch(actions: [hold])).decode(
                ActionStatuses.self)
            #expect(res.actions.first?.state == .done)
        }
    }
}
