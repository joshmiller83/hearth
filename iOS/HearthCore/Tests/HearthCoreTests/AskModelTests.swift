import Foundation
import HearthKit
import HearthKitTestSupport
import Testing

@testable import HearthCore

@Suite("Ask")
@MainActor
struct AskModelTests {
    func loaded() async -> (AppModel, FixtureCalendar, FixtureRelay) {
        let services = AppServices.fixtures(waits: false)
        let app = AppModel(services: services)
        await app.refreshAll()
        let relay = app.relay as! FixtureRelay
        return (app, services.calendar as! FixtureCalendar, relay)
    }

    @Test func aBirthdayBecomesAPlanWaitingForAnOK() async throws {
        let (app, _, _) = await loaded()
        await app.ask.ask("Mom's birthday is next week. Handle it, but run it by me first.")
        let turn = try #require(app.ask.turns.last)
        #expect(turn.phase == .answered)
        #expect(turn.trace.map(\.tool) == ["people_get", "gmail_search", "agenda"])
        #expect(turn.trace[0].detail == "Mom · birthday Tue, Nov 3 · Springfield")
        #expect(turn.trace[1].detail == "account: all · from:carol newer_than:60d · 2 messages")
        #expect(turn.trace.allSatisfy { $0.finished })
        #expect(turn.answer.hasPrefix("Here’s a plan."))
        #expect(turn.answer.contains("\n\nIn her Oct 12 email"))
        #expect(turn.proposals.map(\.kind) == [.note, .remind, .hold, .link])
        // Everything but the store link starts ticked.
        #expect(turn.chosenCount == 3)
        #expect(turn.run == .waiting)
        #expect(!app.ask.isWorking)
    }

    @Test func approvingRunsTheStepsAndUndoTakesThemBack() async throws {
        let (app, calendar, relay) = await loaded()
        await app.ask.ask("Mom's birthday is next week. Handle it, but run it by me first.")
        let id = try #require(app.ask.turns.last?.id)
        await app.ask.approve(id)
        let turn = try #require(app.ask.turns.last)
        #expect(turn.run == .done("Card note drafted, Thursday reminder set, Tuesday call held."))
        #expect(turn.notes.first?.text.hasPrefix("Happy birthday, Mom!") == true)
        #expect(calendar.reminders.map(\.title) == ["Mail Mom's birthday card"])
        #expect(calendar.reminders.first?.due == Fixtures.at("2026-10-29T08:00"))
        let hold = try #require(await relay.submitted.last)
        guard case .createHold(let account, let title, let start, _, _) = hold.kind else {
            Issue.record("expected a hold")
            return
        }
        #expect(account == "work")
        #expect(title == "Call Mom")
        #expect(start == Fixtures.at("2026-11-03T19:30"))
        #expect(hold.context == .ask)

        await app.ask.undo(id)
        #expect(calendar.reminders.isEmpty)
        let removal = try #require(await relay.submitted.last)
        if case .deleteHold(let account, _, let eventId) = removal.kind {
            #expect(account == "work")
            #expect(eventId.hasPrefix("hold-"))
        } else {
            Issue.record("expected the hold to be removed")
        }
        #expect(app.ask.turns.last?.run == .waiting)
        #expect(app.ask.turns.last?.undoProblem == nil)
    }

    @Test func theNextQuestionTellsClaudeWhatHappened() async throws {
        let (app, _, _) = await loaded()
        await app.ask.ask("Mom's birthday is next week. Handle it, but run it by me first.")
        let id = try #require(app.ask.turns.last?.id)
        app.ask.toggle("p1", in: id)
        await app.ask.approve(id)
        await app.ask.ask("When am I free this week?")
        let answer = try #require(app.ask.turns.last)
        #expect(answer.phase == .answered)
        #expect(answer.answer.hasPrefix("Two invites are waiting on you"))
        #expect(answer.trace.map(\.tool) == ["agenda"])
        #expect(answer.proposals.isEmpty)

        // The second turn opened with the result owed for the first turn's proposals.
        let transcript = app.ask.transcript
        let opening = try #require(
            transcript.first { $0.role == .user && $0.content.first?.type == "tool_result" && $0.content.count == 2 })
        #expect(opening.content[0].json["tool_use_id"]?.stringValue == "toolu_propose")
        let result = opening.content[0].json["content"]?.stringValue ?? opening.content[0].json["content"]?[0]?["text"]?.stringValue ?? ""
        #expect(result.contains("Done: Remind me Thursday, 8 AM: mail the card; Hold Tue, Nov 3, 7:30 PM: call Mom."))
        #expect(result.contains("Not run: Draft the birthday card note; Find a garden kneeler"))
        #expect(opening.content[1].text == "When am I free this week?")
        // Append-only: the first turn's messages went back exactly as they were.
        #expect(transcript.filter { $0.role == .assistant }.count == 4)
    }

    @Test func repliesWaitThirtySecondsSoUndoCanStopThem() async throws {
        let (app, _, relay) = await loaded()
        let reply = AskProposal(
            id: "p1", kind: .reply, label: "Reply to Dana", done: "reply to Dana queued", account: "work", messageId: "m1",
            text: "Tuesday at 9 works.")
        app.ask.turns = [AskModel.Turn(id: 1, question: "Answer Dana", proposals: [reply], selected: ["p1"], phase: .answered)]
        await app.ask.approve(1)
        let sent = try #require(await relay.submitted.last)
        #expect(sent.notBefore == sent.approvedAt.addingTimeInterval(AskModel.replyDelay))
        #expect(app.ask.turns[0].run == .done("Reply to Dana queued."))
        await app.ask.undo(1)
        #expect(app.ask.turns[0].undoProblem == nil)
        #expect(app.ask.turns[0].run == .waiting)
    }

    @Test func withoutAClaudeKeyAskSaysSo() async throws {
        let services = AppServices.fixtures(waits: false)
        try services.secrets.write("", for: .claudeKey)
        let app = AppModel(services: services)
        await app.ask.ask("Anything?")
        #expect(app.ask.turns.last?.phase == .failed(ClaudeError.noKey.description))
    }
}

@Suite("Ask: a failed question")
@MainActor
struct AskFailureTests {
    /// A Claude that answers the first question, then fails, then answers again.
    final class Flaky: HTTPTransport, @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var bodies: [JSONValue] = []
        func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw TransportError("not used") }
        func streamLines(_ request: HTTPRequest) async throws -> HTTPLineStream {
            let n = lock.withLock {
                calls += 1
                bodies.append(request.body.flatMap { try? JSONValue.parse($0) } ?? .null)
                return calls
            }
            // Round 3 (the second question) fails before a byte arrives; the rest is the fixture.
            if n == 3 {
                return HTTPLineStream(
                    status: 400,
                    lines: AsyncThrowingStream {
                        $0.yield(#"{"type":"error","error":{"type":"invalid_request_error","message":"nope"}}"#)
                        $0.finish()
                    })
            }
            return try await FixtureClaude().streamLines(request)
        }
    }

    @Test func whatsOwedIsStillOwedAfterAFailure() async throws {
        let flaky = Flaky()
        var services = AppServices.fixtures(waits: false)
        services.makeClaude = { ClaudeClient(apiKey: $0, transport: flaky, retries: 0, pause: { _ in }) }
        let app = AppModel(services: services)
        await app.refreshAll()
        await app.ask.ask("Mom's birthday is next week. Handle it, but run it by me first.")
        await app.ask.ask("When am I free this week?")
        #expect(app.ask.turns.last?.phase != .answered)
        await app.ask.ask("When am I free this week?")
        #expect(app.ask.turns.last?.phase == .answered)
        // The retry still opened with the owed result, so the conversation stayed valid.
        let retry = try #require(flaky.lock.withLock { flaky.bodies.count >= 4 ? flaky.bodies[3] : nil })
        let opening = try #require(retry["messages"]?.arrayValue?.last)
        #expect(opening["content"]?[0]?["type"]?.stringValue == "tool_result")
        #expect(opening["content"]?[0]?["tool_use_id"]?.stringValue == "toolu_propose")
    }
}
