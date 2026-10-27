import Foundation
import HearthKit
import HearthKitTestSupport
import Testing

@testable import HearthCore

@Suite("People")
@MainActor
struct PeopleModelTests {
    func loaded(_ adjust: (AppServices) throws -> Void = { _ in }) async throws -> AppModel {
        let services = AppServices.fixtures(waits: false)
        try adjust(services)
        let app = AppModel(services: services)
        await app.refreshAll()
        return app
    }

    func lastAction(_ app: AppModel) async -> ApprovedAction? {
        await (app.relay as! FixtureRelay).submitted.last
    }

    @Test func theCircleAndWhatsComingUp() async throws {
        let app = try await loaded()
        let people = app.people
        #expect(people.ordered.map(\.shortName) == ["Robin", "Mom"])
        #expect(people.occasions.map(\.title) == ["Jordan's birthday", "Mom’s birthday", "Anniversary with Robin"])
        let birthday = try #require(people.occasions.first { $0.title == "Mom’s birthday" })
        #expect(people.line(birthday) == "Tue, Nov 3 · mail a card by Thursday")
        let anniversary = try #require(people.partnerOccasion)
        #expect(people.line(anniversary) == "Sat, Nov 14 · plan it quietly")
        await people.refreshPlans()
        #expect(people.line(anniversary) == "Sat, Nov 14 · three ideas ready")
    }

    @Test func ideasRunStepByStepAndUndo() async throws {
        let app = try await loaded()
        let people = app.people
        await people.refreshIdeas()
        #expect(people.ideas.map(\.title) == ["Call Mom Tuesday evening", "A new garden kneeler", "A note for Robin's long Wednesday"])
        let hold = try #require(people.ideas.first?.actions.first)
        await people.run(hold)
        #expect(people.ran[hold.id]?.text == "Tuesday call held.")
        if case .createHold(let account, let title, _, _, let notes)? = await lastAction(app)?.kind {
            #expect(account == "work")
            #expect(title == "Call Mom")
            #expect(notes == "Held by Hearth.")
        } else {
            Issue.record("expected a hold")
        }
        await people.undo(hold.id)
        #expect(people.ran[hold.id] == nil)
        if case .deleteHold? = await lastAction(app)?.kind {} else { Issue.record("expected the hold to be removed") }

        let note = try #require(people.ideas.last?.actions.last)
        await people.run(note)
        #expect(people.ran[note.id]?.note == "Thinking of you on the long day. Dinner's on me tonight.")
        // Once a day: asking again today keeps them.
        await people.refreshIdeas()
        #expect(people.ran[note.id] != nil)
    }

    @Test func thePartnerPlanHoldsTheEveningPrivately() async throws {
        let app = try await loaded()
        let people = app.people
        await people.refreshPlans()
        #expect(people.plan.ideas.count == 3)
        #expect(people.picked?.title == "Thai dinner downtown")
        #expect(people.steps.map(\.done) == [true, true, false, false])
        #expect(people.steps.first?.label == "Saturday evening is open for you both")
        #expect(people.cta == "Plan the Thai dinner")
        #expect(people.ctaNote == "Holds Sat 7:00 PM on work@ as private. Robin's calendar stays untouched.")

        await people.makePlan()
        let hold = try #require(await lastAction(app))
        #expect(hold.context == .surprise)
        if case .createHold(let account, _, let start, _, let notes) = hold.kind {
            #expect(account == "work")
            #expect(start == Fixtures.at("2026-11-14T19:00"))
            #expect(notes?.contains(SurpriseMarker.tag) == true)
        }
        #expect(people.ctaNote == "Held Sat 7:00 PM on work@ as private.")
        // The plan holds: another idea can't be picked until it's undone.
        people.pick("plan3")
        #expect(people.picked?.id == "plan1")
        await people.undoPlan()
        #expect(people.plan.hold == nil)
        people.pick("plan3")
        #expect(people.cta == "Plan a night in")
    }

    @Test func withTheGuardOffTheHoldIsPlain() async throws {
        let app = try await loaded()
        let people = app.people
        await people.refreshPlans()
        people.setSurpriseGuard(false)
        #expect(people.ctaNote.hasPrefix("Surprise guard is off"))
        await people.makePlan()
        let hold = try #require(await lastAction(app))
        #expect(hold.context == .ask)
        if case .createHold(_, _, _, _, let notes) = hold.kind { #expect(notes == "Held by Hearth.") }
    }

    @Test func lovesAndThePartnerFromContacts() async throws {
        let app = try await loaded { try $0.database.remove(key: StoreKey.people) }
        let people = app.people
        #expect(people.partner == nil)
        await people.ensurePartner()
        #expect(people.partner?.name == "Robin Rivera")
        people.addLove("Lilacs")
        people.addLove("Lilacs")
        #expect(people.plan.loves == ["Thai food", "Mystery novels", "Lilacs"])
        people.removeLove("Mystery novels")
        #expect(app.services.database.load(PartnerPlan.self, key: StoreKey.partnerPlan)?.loves == ["Thai food", "Lilacs"])
    }
}
