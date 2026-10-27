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

    func testSources() async {
        let host = await screen(SourcesView())
        assertSnapshot(of: host, as: .image(on: .iPhone13ProMax, precision: 0.99, perceptualPrecision: 0.98))
    }
}
