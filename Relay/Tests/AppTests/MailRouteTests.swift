import Foundation
import HearthKit
import HearthKitTestSupport
import Jobs
import RelayCore
import Testing
import Vapor

@testable import App

@Suite("Mail sweep")
struct MailRouteTests {
    @Test func theSweepFillsTheQueuesAndKeepsWhatItMust() async throws {
        try await withTestApp { t in
            let res = try await t.app.client2.send(.GET, RelayPath.mailSnapshot, key: try await t.key())
            #expect(res.status == .ok)
            let snapshot = try res.decode(MailSnapshot.self)
            #expect(snapshot.items(in: .jobHunt).count == 3)
            #expect(snapshot.items(in: .archive).filter { $0.bundle == "GitHub" }.count == 2)
            #expect(snapshot.items(in: .delete).map(\.item.id) == ["m14"])
            // No Claude key on this relay: people's mail waits, unsorted, in the inbox.
            let kept = snapshot.kept()
            #expect(Set(kept.map(\.item.id)) == ["m1", "m2", "m3", "m10", "m15", "m16"])
            #expect(kept.first { $0.item.id == "m15" }?.tag == "Security")
            #expect(kept.first { $0.item.id == "m1" }?.tag == "Needs a look")
            #expect(snapshot.jobHuntLabels == ["work": "Label_7"])
            #expect(snapshot.problems.map(\.source) == ["kid"])
            #expect(t.google.searches == ["in:inbox", MailSweepJob.oldPromoQuery])
        }
    }

    @Test func haikuSortsTheLeftoversOnce() async throws {
        let reply = SortPrompt.Reply(results: [
            .init(index: 0, queue: "reply", tag: "Needs you", reason: "Recruiter wants times"),
            .init(index: 1, queue: "reply", tag: "Needs you", reason: "Shift question"),
            .init(index: 2, queue: "reply", tag: "Family", reason: "Holiday plans"),
            .init(index: 3, queue: "keep", tag: "School", reason: "Practice moved"),
        ])
        let text = String(decoding: try HearthJSON.encode(reply), as: UTF8.self)
        let transport = ScriptedTransport([ScriptedTransport.message(text: text, model: "claude-haiku-5-5")])
        let claude = ClaudeClient(apiKey: "k", transport: transport, pause: { _ in })
        try await withTestApp(claude: claude) { t in
            let key = try await t.key()
            let first = try await t.app.client2.send(.GET, RelayPath.mailSnapshot + "?refresh=1", key: key).decode(MailSnapshot.self)
            #expect(first.items(in: .reply).map(\.item.id).sorted() == ["m1", "m2", "m3", "m4"])
            #expect(first.items(in: .reply).first { $0.item.id == "m1" }?.sortedBy == .claude)
            #expect(transport.requests.count == 1)
            #expect(transport.bodies.first?["model"]?.stringValue == "claude-haiku-5-5")

            // The next sweep remembers: Claude isn't asked again.
            t.clock.advance(15 * 60)
            _ = try await t.app.client2.send(.GET, RelayPath.mailSnapshot + "?refresh=1", key: key)
            #expect(transport.requests.count == 1)
        }
    }

    @Test func archivingRemovesMailFromTheQueue() async throws {
        try await withTestApp { t in
            let key = try await t.key()
            _ = try await t.app.client2.send(.GET, RelayPath.mailSnapshot, key: key)
            let archive = ApprovedAction(
                id: "a1", kind: .modifyMail(account: "home", messageIds: ["m8", "m9"], change: .archive),
                context: .inbox, approvedAt: t.clock.now)
            _ = try await t.app.client2.send(.POST, RelayPath.actions, key: key, json: ActionBatch(actions: [archive]))
            let after = try await t.app.client2.send(.GET, RelayPath.mailSnapshot, key: key).decode(MailSnapshot.self)
            #expect(after.items(in: .archive).filter { $0.bundle == "GitHub" }.isEmpty)
        }
    }

    @Test func aRepliedMessageLeavesTheReplyQueueForGood() async throws {
        try await withTestApp { t in
            let key = try await t.key()
            _ = try await t.app.client2.send(.GET, RelayPath.mailSnapshot, key: key)
            let reply = ApprovedAction(
                id: "r1", kind: .reply(account: "school", messageId: "m4", body: "Count me in.", replyAll: false),
                context: .inbox, approvedAt: t.clock.now)
            _ = try await t.app.client2.send(.POST, RelayPath.actions, key: key, json: ActionBatch(actions: [reply]))
            #expect(
                try await t.app.client2.send(.GET, RelayPath.mailSnapshot, key: key).decode(MailSnapshot.self)
                    .items(in: .reply).isEmpty)
            // It's still in Gmail's inbox, but the next sweep leaves it out.
            let swept = try await t.app.client2.send(.GET, RelayPath.mailSnapshot + "?refresh=1", key: key).decode(MailSnapshot.self)
            #expect(!swept.items.contains { $0.item.id == "m4" })
        }
    }

    @Test func threadsComeWithTheirText() async throws {
        try await withTestApp { t in
            let res = try await t.app.client2.send(.GET, RelayPath.mailThreads + "/work/t-m1", key: try await t.key())
            let thread = try res.decode(ThreadResponse.self)
            #expect(thread.messages.map(\.body) == ["Could you share a few windows?"])
            #expect(thread.messages.first?.from == "Dana Whitfield <dana@northbeam.example>")
        }
    }
}
