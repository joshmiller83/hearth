import HearthCore
import SnapshotTesting
import SwiftUI
import XCTest

@testable import Hearth

/// The screens on the fixtures, compared with recorded images (local only, `make snapshots`).
/// Re-record after a deliberate design change with `make snapshots RECORD=1`.
@MainActor
final class ScreenSnapshotTests: XCTestCase {
    func screen(_ view: some View) async -> UIViewController {
        let model = AppEnvironment.makeModel(mode: .fixtures)
        await model.refreshAll()
        let host = UIHostingController(rootView: NavigationStack { view }.environment(model).preferredColorScheme(.dark))
        host.overrideUserInterfaceStyle = .dark
        return host
    }

    func testToday() async {
        let host = await screen(TodayView(tab: .constant(.today), showCapture: .constant(false), path: .constant([])))
        assertSnapshot(of: host, as: .image(on: .iPhone13ProMax, precision: 0.99, perceptualPrecision: 0.98))
    }

    func testPlans() async {
        let host = await screen(PlansView(showCapture: .constant(false)))
        assertSnapshot(of: host, as: .image(on: .iPhone13ProMax, precision: 0.99, perceptualPrecision: 0.98))
    }

    func testInbox() async {
        let host = await screen(InboxView())
        assertSnapshot(of: host, as: .image(on: .iPhone13ProMax, precision: 0.99, perceptualPrecision: 0.98))
    }

    func testAsk() async {
        let model = AppEnvironment.makeModel(mode: .fixtures)
        await model.refreshAll()
        await model.ask.ask("Mom's birthday is next week. Handle it, but run it by me first.")
        let host = UIHostingController(rootView: NavigationStack { AskView() }.environment(model).preferredColorScheme(.dark))
        host.overrideUserInterfaceStyle = .dark
        assertSnapshot(of: host, as: .image(on: .iPhone13ProMax, precision: 0.99, perceptualPrecision: 0.98))
    }

    func testSignals() async {
        let host = await screen(SignalsView(tab: .constant(.today), path: .constant([])))
        assertSnapshot(of: host, as: .image(on: .iPhone13ProMax, precision: 0.99, perceptualPrecision: 0.98))
    }

    func testPeople() async {
        let model = AppEnvironment.makeModel(mode: .fixtures)
        await model.refreshAll()
        await model.people.refreshIdeas()
        let host = UIHostingController(
            rootView: NavigationStack { PeopleView(tab: .constant(.people)) }.environment(model).preferredColorScheme(.dark))
        host.overrideUserInterfaceStyle = .dark
        assertSnapshot(of: host, as: .image(on: .iPhone13ProMax, precision: 0.99, perceptualPrecision: 0.98))
    }

    func testPartnerPlanner() async {
        let model = AppEnvironment.makeModel(mode: .fixtures)
        await model.refreshAll()
        await model.people.refreshPlans()
        let host = UIHostingController(rootView: NavigationStack { PartnerPlannerView() }.environment(model).preferredColorScheme(.dark))
        host.overrideUserInterfaceStyle = .dark
        assertSnapshot(of: host, as: .image(on: .iPhone13ProMax, precision: 0.99, perceptualPrecision: 0.98))
    }

    func testAroundTown() async {
        let host = await screen(ScreenScroll { AroundTownSection() })
        assertSnapshot(of: host, as: .image(on: .iPhone13ProMax, precision: 0.99, perceptualPrecision: 0.98))
    }

    func testFeedsChat() async {
        let model = AppEnvironment.makeModel(mode: .fixtures)
        await model.refreshAll()
        await model.town.send("The community center has a calendar online somewhere. Can you add it?")
        let host = UIHostingController(rootView: NavigationStack { FeedsView() }.environment(model).preferredColorScheme(.dark))
        host.overrideUserInterfaceStyle = .dark
        assertSnapshot(of: host, as: .image(on: .iPhone13ProMax, precision: 0.99, perceptualPrecision: 0.98))
    }

    func testFacebook() async {
        let model = AppEnvironment.makeModel(mode: .fixtures)
        await model.refreshAll()
        await model.facebook.refresh()
        await model.facebook.tell("Only the family group and anything from Lou. Skip Marketplace.")
        let host = UIHostingController(rootView: NavigationStack { FacebookView() }.environment(model).preferredColorScheme(.dark))
        host.overrideUserInterfaceStyle = .dark
        assertSnapshot(of: host, as: .image(on: .iPhone13ProMax, precision: 0.99, perceptualPrecision: 0.98))
    }

    func testSources() async {
        let host = await screen(SourcesView())
        assertSnapshot(of: host, as: .image(on: .iPhone13ProMax, precision: 0.99, perceptualPrecision: 0.98))
    }
}
