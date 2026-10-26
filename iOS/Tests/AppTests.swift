import HearthCore
import HearthKit
import Testing
import UIKit

@testable import Hearth

@Suite("App wiring")
@MainActor
struct AppTests {
    @Test func launchModeFollowsTheArgument() {
        #expect(LaunchMode.current(arguments: ["Hearth"]) == .live)
        #expect(LaunchMode.current(arguments: ["Hearth", "-UITestFixtures"]) == .fixtures)
    }

    @Test func fixturesShowTheFictionalHousehold() async {
        let model = AppEnvironment.makeModel(mode: .fixtures)
        await model.refreshAll()
        #expect(model.household.ownerName == "Sam")
        #expect(model.plans.invites.count == 2)
    }

    @Test(arguments: [
        Typeface.display, Typeface.displayHeavy, Typeface.regular, Typeface.medium, Typeface.semibold, Typeface.bold,
    ])
    func everyBundledFontLoads(name: String) {
        #expect(UIFont(name: name, size: 12) != nil, "\(name) isn't registered; check UIAppFonts in project.yml")
    }
}
