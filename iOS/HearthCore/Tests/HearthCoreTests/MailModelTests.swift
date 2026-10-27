import Foundation
import HearthKit
import HearthKitTestSupport
import Testing

@testable import HearthCore

@Suite("Inbox")
@MainActor
struct InboxModelTests {
    func loaded() async -> AppModel {
        let app = AppModel(services: .fixtures(waits: false))
        await app.refreshAll()
        return app
    }

    func settle(_ inbox: InboxModel) async {
        for _ in 0..<50 where inbox.approvals.contains(where: { !$0.isFinished }) { await Task.yield() }
    }

    @Test func queuesCountAndFilterByAccount() async {
        let app = await loaded()
        let inbox = app.inbox
        #expect(inbox.phase == .loaded)
        #expect(MailQueue.allCases.map(inbox.count) == [5, 3, 5, 1])
        inbox.account = "home"
        #expect(inbox.count(.archive) == 3)
        #expect(inbox.accounts == ["home", "work", "school", "town", "robin", "kid"])
    }

    @Test func gitHubChatterIsOneRow() async throws {
        let app = await loaded()
        let inbox = app.inbox
        inbox.queue = .archive
        let github = try #require(inbox.rows.first { $0.first.bundle == "GitHub" })
        #expect(github.items.count == 2)
        #expect(inbox.rows.count == 4)
        #expect(inbox.headline == "Archive · 5 across 3 accounts")
    }

    @Test func keptMailIsNamedNotMoved() async {
        let app = await loaded()
        let inbox = app.inbox
        #expect(inbox.keptNote == "Kept in your inbox: 1 github, 1 security. Those never move without you.")
    }

    @Test func unsortedMailIsWaitingNotKept() async throws {
        let app = await loaded()
        let inbox = app.inbox
        #expect(inbox.unsortedNote == nil)
        let stray = MailItem(
            id: "u1", threadId: "u1", account: "home", from: "Someone <someone@example.com>", subject: "Hello", date: Fixtures.now)
        inbox.sorted?.items.append(
            TriagedMail(item: stray, queue: nil, tag: "Needs a look", reason: TriagedMail.noKeyReason, sortedBy: .unsorted))
        #expect(
            inbox.unsortedNote
                == "1 message no rule caught waits for the relay's own Claude key to sort it. Until then it stays in your inbox.")
        #expect(inbox.keptNote == "Kept in your inbox: 1 github, 1 security. Those never move without you.")
    }

    @Test func approvingAQueueSendsOneBatchPerAccount() async throws {
        let app = await loaded()
        let inbox = app.inbox
        inbox.queue = .archive
        inbox.approve()
        #expect(inbox.approvals.last?.state == .waiting(until: Fixtures.now.addingTimeInterval(10)))
        #expect(inbox.count(.archive) == 0)
        #expect(inbox.actionLabel == "Nothing to archive")
        await settle(inbox)
        #expect(inbox.approvals.last?.state == .done("Archived 5"))
        #expect(inbox.count(.archive) == 0)
        let relay = try #require(app.relay as? FixtureRelay)
        let sent = await relay.submitted.map(\.kind)
        #expect(sent.count == 3)
        #expect(sent.allSatisfy { if case .modifyMail(_, _, let change) = $0 { change == .archive } else { false } })
    }

    @Test func filingJobHuntAddsTheLabelWhereItExists() async throws {
        let app = await loaded()
        app.inbox.queue = .jobHunt
        app.inbox.approve()
        await settle(app.inbox)
        let relay = try #require(app.relay as? FixtureRelay)
        let kinds = await relay.submitted.map(\.kind)
        #expect(
            kinds == [
                .modifyMail(
                    account: "work", messageIds: ["m5", "m6", "m7"],
                    change: MailChange(archive: true, markRead: true, addLabels: ["job hunt"]))
            ])
    }

    @Test func deleteMeansTrash() async throws {
        let app = await loaded()
        app.inbox.queue = .delete
        #expect(app.inbox.actionLabel == "Move 1 to Trash")
        app.inbox.approve()
        await settle(app.inbox)
        let relay = try #require(app.relay as? FixtureRelay)
        #expect(await relay.submitted.map(\.kind) == [.modifyMail(account: "robin", messageIds: ["m14"], change: .trash)])
    }

    @Test func undoInsideTheWindowSendsNothing() async throws {
        let app = await loaded()
        app.inbox.queue = .archive
        app.inbox.approve()
        app.inbox.undo(try #require(app.inbox.approvals.last?.id))
        for _ in 0..<20 { await Task.yield() }
        #expect(app.inbox.approvals.isEmpty)
        #expect(app.inbox.count(.archive) == 5)
        let relay = try #require(app.relay as? FixtureRelay)
        #expect(await relay.submitted.isEmpty)
    }

    @Test func leftOutRowsStayInTheInbox() async throws {
        let app = await loaded()
        let inbox = app.inbox
        inbox.queue = .archive
        let github = try #require(inbox.rows.first { $0.isBundle })
        inbox.toggle(github)
        // It stays in place, dimmed, until the queue is opened again.
        #expect(inbox.isLeftOut(github))
        #expect(inbox.rows.count == 4)
        #expect(inbox.leftOutRows.isEmpty)
        #expect(inbox.actionLabel == "Archive 3")
        #expect(inbox.actionNote.hasSuffix("2 left out stay in your inbox."))
        #expect(inbox.keptNote?.contains("2 left out") == true)
        inbox.queue = .reply
        inbox.queue = .archive
        #expect(inbox.rows.count == 3)
        #expect(inbox.leftOutRows.map(\.items.count) == [2])
        inbox.approve()
        await settle(inbox)
        let relay = try #require(app.relay as? FixtureRelay)
        let sent = await relay.submitted.flatMap { action -> [String] in
            if case .modifyMail(_, let ids, _) = action.kind { ids } else { [] }
        }
        #expect(!sent.contains(where: github.items.map(\.item.id).contains))
        #expect(inbox.count(.archive) == 0)
        // Put back, it's in the queue again.
        inbox.toggle(try #require(inbox.leftOutRows.first))
        #expect(inbox.count(.archive) == 2)
        #expect(inbox.leftOutCount == 0)
    }

    @Test func anErrantReplyLeavesTodayAndCanBeArchived() async throws {
        let app = await loaded()
        let inbox = app.inbox
        inbox.queue = .reply
        let first = try #require(inbox.rows.first)
        #expect(TodaySummary.make(app: app).needsYou.contains { $0.id == first.id })
        inbox.toggle(first)
        #expect(inbox.count(.reply) == 4)
        #expect(!TodaySummary.make(app: app).needsYou.contains { $0.id == first.id })
        inbox.archiveLeftOut()
        #expect(inbox.leftOutCount == 0)
        await settle(inbox)
        #expect(inbox.approvals.last?.state == .done("Archived 1"))
        let relay = try #require(app.relay as? FixtureRelay)
        #expect(
            await relay.submitted.map(\.kind) == [
                .modifyMail(account: first.first.item.account, messageIds: [first.first.item.id], change: .archive)
            ])
        #expect(inbox.leftOut.isEmpty)
    }

    @Test func leavingOutIsRememberedAndPrunedWhenTheMailIsGone() async throws {
        let services = AppServices.fixtures(waits: false)
        let app = AppModel(services: services)
        await app.refreshAll()
        app.inbox.leaveOut("work:m1")
        app.inbox.leaveOut("home:gone")
        let again = AppModel(services: services)
        #expect(again.inbox.leftOut == ["work:m1", "home:gone"])
        await again.refreshAll()
        #expect(again.inbox.leftOut == ["work:m1"])
    }

    @Test func aBatchCanStartWhileAnotherWaits() async throws {
        let app = AppModel(services: .fixtures())
        await app.refreshAll()
        let inbox = app.inbox
        inbox.queue = .archive
        inbox.approve()
        inbox.queue = .delete
        #expect(inbox.actionLabel == "Move 1 to Trash")
        inbox.approve()
        #expect(inbox.approvals.map(\.queue) == [.archive, .delete])
        #expect(inbox.approvals.map { inbox.doing($0) } == ["Archiving 5 in 10 s", "Trashing 1 in 10 s"])
        inbox.undo(inbox.approvals[0].id)
        #expect(inbox.approvals.map(\.queue) == [.delete])
        #expect(inbox.count(.archive) == 5)
    }

    @Test func repliesAreNotBatchApproved() async {
        let app = await loaded()
        let inbox = app.inbox
        inbox.queue = .reply
        inbox.approve()
        #expect(inbox.approvals.isEmpty)
        #expect(inbox.actionLabel == "Open the first")
    }
}

@Suite("Thread")
@MainActor
struct ThreadModelTests {
    func thread() async throws -> (AppModel, ThreadModel) {
        let app = AppModel(services: .fixtures(waits: false))
        await app.refreshAll()
        let mail = try #require(app.inbox.snapshot?.items.first { $0.item.id == "m1" })
        let thread = ThreadModel(mail: mail, app: app)
        await thread.load()
        return (app, thread)
    }

    @Test func aDraftComesWithItsSlotsAndSources() async throws {
        let (app, thread) = try await thread()
        _ = app
        #expect(thread.messages.count == 1)
        await thread.draft()
        #expect(thread.drafting == .ready)
        #expect(thread.body.hasPrefix("Hi Dana,"))
        #expect(thread.offeredSlots.count == 2)
        #expect(thread.holdLabel == "Hold these 2 slots on my calendar until Dana picks one")
        #expect(thread.lookedAt == "Free time across every calendar, Tue–Wed · Dana's message")
        #expect(thread.fromLine == "Sends from sam@rivera.example · threaded reply")
        await thread.draft(.shorter)
        #expect(thread.body.contains("Glad to."))
        await thread.draft(.drafted)
        #expect(thread.body.contains("I enjoyed Friday"))
    }

    @Test func sendingTomorrowMorningHoldsTheSlots() async throws {
        let (app, thread) = try await thread()
        await thread.draft()
        let morning = thread.tomorrowMorning
        #expect(morning == Fixtures.at("2026-10-27T08:00"))
        await thread.send(at: morning)
        #expect(thread.sending == .scheduled(morning))
        let relay = try #require(app.relay as? FixtureRelay)
        let sent = await relay.submitted
        #expect(sent.first?.notBefore == morning)
        #expect(sent.count == 3)
        guard case .createHold(let account, let title, let start, _, _) = sent[1].kind else {
            Issue.record("expected a hold")
            return
        }
        #expect(account == "work")
        #expect(title == "Hold: Next steps: Senior Engineer")
        #expect(start == Fixtures.at("2026-10-27T09:00"))
        // Answered: it leaves the Reply queue.
        #expect(app.inbox.snapshot?.items.contains { $0.item.id == "m1" } == false)
    }

    @Test func withoutHoldsOnlyTheReplyGoes() async throws {
        let (app, thread) = try await thread()
        await thread.draft()
        thread.holdSlots = false
        await thread.send()
        #expect(thread.sending == .sent)
        let relay = try #require(app.relay as? FixtureRelay)
        #expect(await relay.submitted.count == 1)
    }
}
