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

    func testSources() async {
        let host = await screen(SourcesView())
        assertSnapshot(of: host, as: .image(on: .iPhone13ProMax, precision: 0.99, perceptualPrecision: 0.98))
    }
}
