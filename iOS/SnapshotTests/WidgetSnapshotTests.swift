import HearthCore
import HearthKit
import HearthKitTestSupport
import SnapshotTesting
import SwiftUI
import XCTest

/// The StandBy widgets on the design's Monday: as a Home Screen tile, and as
/// StandBy shows them (no container background, on black, scaled up).
@MainActor
final class WidgetSnapshotTests: XCTestCase {
    let snapshot = WidgetSnapshot.make(
        agenda: Agenda(events: Fixtures.week, household: Fixtures.household), now: Fixtures.now, fetchedAt: Fixtures.now)

    func tile(_ view: some View, standBy: Bool) -> some View {
        view
            .padding(16)
            .frame(width: 170, height: 170)
            .background(standBy ? Color.black : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: standBy ? 0 : 22, style: .continuous))
            .scaleEffect(standBy ? 1.6 : 1)
            .frame(width: standBy ? 272 : 170, height: standBy ? 272 : 170)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
    }

    func check(
        _ view: some View, named name: String, standBy: Bool,
        file: StaticString = #filePath, testName: String = #function, line: UInt = #line
    ) {
        let size = standBy ? CGSize(width: 272, height: 272) : CGSize(width: 170, height: 170)
        assertSnapshot(
            of: tile(view, standBy: standBy),
            as: .image(precision: 0.99, perceptualPrecision: 0.98, layout: .fixed(width: size.width, height: size.height)),
            named: name, file: file, testName: testName, line: line)
    }

    func testNextUp() {
        let entry = HearthEntry(date: Fixtures.now, snapshot: snapshot)
        check(NextUpView(entry: entry, familyOverride: .systemSmall), named: "home", standBy: false)
        check(NextUpView(entry: entry, familyOverride: .systemSmall), named: "standby", standBy: true)
    }

    func testToday() {
        let entry = HearthEntry(date: Fixtures.at("2026-10-26T12:30"), snapshot: snapshot)
        check(TodayListView(entry: entry, familyOverride: .systemSmall), named: "home", standBy: false)
        check(TodayListView(entry: entry, familyOverride: .systemSmall), named: "standby", standBy: true)
    }

    func testNeedsYouAndBrief() {
        var withBrief = snapshot
        withBrief.repliesReady = 4
        withBrief.briefHeadline = "Two invites and four replies need you. The rest can wait."
        withBrief.briefDay = "2026-10-26"
        let entry = HearthEntry(date: Fixtures.now, snapshot: withBrief)
        check(NeedsYouView(entry: entry, familyOverride: .systemSmall), named: "needs-you", standBy: true)
        check(BriefView(entry: entry), named: "brief", standBy: true)
    }

    func testNothingLeftToday() {
        let entry = HearthEntry(date: Fixtures.at("2026-10-26T23:30"), snapshot: snapshot)
        check(NextUpView(entry: entry, familyOverride: .systemSmall), named: "late", standBy: true)
    }
}
