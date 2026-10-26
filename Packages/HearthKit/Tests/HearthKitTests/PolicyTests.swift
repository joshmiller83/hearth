import Foundation
import HearthKitTestSupport
import Testing

@testable import HearthKit

@Suite("Trust policies")
struct PolicyTests {
    let now = Fixtures.now
    let household = Fixtures.household

    func action(_ kind: ActionKind, context: ActionContext = .inbox, approvedAt: Date? = nil, notBefore: Date? = nil, id: String = "a1")
        -> ApprovedAction
    {
        ApprovedAction(id: id, kind: kind, context: context, approvedAt: approvedAt ?? now, notBefore: notBefore)
    }

    // MARK: Ask before acting

    @Test func aFreshApprovalPasses() {
        #expect(ApprovalPolicy.check(action(.modifyMail(account: "work", messageIds: ["m1"], change: .archive)), now: now) == nil)
    }

    @Test func approvalsNeedAKeyAPastTimeAndFreshness() {
        let archive = ActionKind.modifyMail(account: "work", messageIds: ["m1"], change: .archive)
        #expect(ApprovalPolicy.check(action(archive, id: " "), now: now) == .missingKey)
        #expect(ApprovalPolicy.check(action(archive, approvedAt: now.addingTimeInterval(3600)), now: now) == .approvalInFuture)
        #expect(ApprovalPolicy.check(action(archive, approvedAt: now.addingTimeInterval(-2 * 86400)), now: now) == .approvalTooOld)
    }

    @Test func aScheduledSendMayWaitButNotForever() {
        let reply = ActionKind.reply(account: "work", messageId: "m1", body: "Thanks!", replyAll: false)
        let tomorrow = action(reply, approvedAt: now.addingTimeInterval(-2 * 86400), notBefore: now.addingTimeInterval(3600))
        #expect(ApprovalPolicy.check(tomorrow, now: now) == nil)
        let tooFar = action(reply, notBefore: now.addingTimeInterval(40 * 86400))
        #expect(ApprovalPolicy.check(tooFar, now: now) == .notBeforeTooFar)
    }

    // MARK: Surprise guard

    @Test func surprisePlansStayOffThePartnersAccounts() {
        let hold = ActionKind.createHold(account: "robin", title: "Dinner", start: now, end: now.addingTimeInterval(3600), notes: nil)
        let refusal = SurpriseGuard.refusal(for: action(hold, context: .surprise), household: household, guardOn: true)
        #expect(refusal == "The surprise guard keeps plans for Robin off robin. Hold it on work instead.")
    }

    @Test func surprisePlansMayHoldTimeOnTheOwnersAccount() {
        let hold = ActionKind.createHold(account: "work", title: "Dinner", start: now, end: now.addingTimeInterval(3600), notes: nil)
        #expect(SurpriseGuard.refusal(for: action(hold, context: .surprise), household: household, guardOn: true) == nil)
    }

    @Test func theGuardOnlyAppliesToSurprisePlansWhileItsOn() {
        let hold = ActionKind.createHold(account: "kid", title: "Practice", start: now, end: now.addingTimeInterval(3600), notes: nil)
        #expect(SurpriseGuard.refusal(for: action(hold, context: .plans), household: household, guardOn: true) == nil)
        #expect(SurpriseGuard.refusal(for: action(hold, context: .surprise), household: household, guardOn: false) == nil)
        #expect(SurpriseGuard.refusal(for: action(hold, context: .surprise), household: household, guardOn: true) != nil)
    }

    @Test func surprisePlansDontAnswerInvites() {
        let rsvp = ActionKind.rsvp(account: "work", calendarId: "primary", eventId: "e1", response: .accepted)
        #expect(SurpriseGuard.refusal(for: action(rsvp, context: .surprise), household: household, guardOn: true) != nil)
    }

    // MARK: Quiet hours

    @Test(arguments: [
        ("2026-10-26T20:59", false), ("2026-10-26T21:00", true), ("2026-10-26T23:30", true),
        ("2026-10-27T03:00", true), ("2026-10-27T06:59", true), ("2026-10-27T07:00", false), ("2026-10-27T12:00", false),
    ])
    func quietFromNineToSeven(local: String, quiet: Bool) {
        #expect(QuietHours().isQuiet(at: Fixtures.at(local), zone: Fixtures.zone) == quiet)
    }

    @Test func heldPushesGoOutAtSeven() {
        let q = QuietHours()
        #expect(q.nextAllowed(after: Fixtures.at("2026-10-26T23:15"), zone: Fixtures.zone) == Fixtures.at("2026-10-27T07:00"))
        #expect(q.nextAllowed(after: Fixtures.at("2026-10-27T03:00"), zone: Fixtures.zone) == Fixtures.at("2026-10-27T07:00"))
        #expect(q.nextAllowed(after: Fixtures.at("2026-10-27T09:00"), zone: Fixtures.zone) == Fixtures.at("2026-10-27T09:00"))
    }

    @Test func familyAndUrgentGetThrough() {
        let night = Fixtures.at("2026-10-26T23:00")
        let q = QuietHours()
        #expect(!q.shouldDeliver(.normal, at: night, zone: Fixtures.zone))
        #expect(q.shouldDeliver(.family, at: night, zone: Fixtures.zone))
        #expect(q.shouldDeliver(.urgent, at: night, zone: Fixtures.zone))
        #expect(QuietHours(enabled: false).shouldDeliver(.normal, at: night, zone: Fixtures.zone))
    }

    // MARK: Busy only

    @Test func busyOnlyDropsTheDetails() {
        let event = AgendaEvent(
            id: "x", source: .google(account: "robin", calendarId: "primary", calendarName: "primary"),
            sourceEventId: "x", title: "book club", start: now, end: now.addingTimeInterval(3600),
            location: "Library", notes: "bring the book", meetingLinks: ["https://zoom.us/j/1"],
            myResponse: .needsAction, organizer: "a@b.c", attendeeCount: 8, url: "https://calendar")
        let redacted = BusyOnly.redact(event)
        #expect(redacted.busyOnly)
        #expect(redacted.location == nil && redacted.notes == nil && redacted.url == nil && redacted.organizer == nil)
        #expect(redacted.meetingLinks.isEmpty && redacted.attendeeCount == 0)
        #expect(redacted.myResponse == .none)
        #expect(BusyOnly.title(for: redacted, partnerName: "Robin") == "Robin is busy: book club")
    }
}
