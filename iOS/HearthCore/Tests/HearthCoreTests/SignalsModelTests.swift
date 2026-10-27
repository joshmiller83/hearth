import Foundation
import HearthKit
import HearthKitTestSupport
import Testing

@testable import HearthCore

@Suite("Signals")
@MainActor
struct SignalsModelTests {
    func loaded() async -> (AppModel, AppServices) {
        let services = AppServices.fixtures(waits: false)
        let app = AppModel(services: services)
        await app.refreshAll()
        return (app, services)
    }

    @Test func mailAndWeatherMakeOneList() async {
        let (app, _) = await loaded()
        let signals = app.signals
        let titles = signals.all.map(\.title)
        #expect(titles.contains("Frost tonight, low of 29°F"))
        #expect(titles.contains("Review requested on #218"))
        #expect(titles.contains("Thanksgiving plans??"))
        #expect(signals.categories == [.work, .family, .church])
        #expect(signals.bundles.map(\.id).contains("github"))
        #expect(signals.summary.hasSuffix("are worth a look."))
        signals.filter = .church
        #expect(signals.worth.map(\.title) == ["Trunk or Treat shifts"])
    }

    @Test func aFrostSignalSetsAReminder() async throws {
        let (app, services) = await loaded()
        let frost = try #require(app.signals.all.first { $0.monogram == "WX" })
        guard case .remind(_, let title, let at) = frost.actions.first else {
            Issue.record("expected a reminder button")
            return
        }
        await app.signals.remind(frost, title: title, at: at)
        let calendar = services.calendar as! FixtureCalendar
        #expect(calendar.reminders.map(\.title) == ["Cover the tender plants"])
        #expect(app.signals.done[frost.id] == "Reminder set for 5:00 PM")
    }

    @Test func markReadArchivesTheBundle() async throws {
        let (app, _) = await loaded()
        let github = try #require(app.signals.bundles.first { $0.id == "github" })
        guard case .markRead(_, let mail) = github.action else {
            Issue.record("expected Mark read")
            return
        }
        await app.signals.markRead(github, mail: mail)
        let relay = app.relay as! FixtureRelay
        let sent = try #require(await relay.submitted.last)
        guard case .modifyMail(let account, let ids, let change) = sent.kind else {
            Issue.record("expected an archive")
            return
        }
        #expect(account == "home")
        #expect(Set(ids) == ["m8", "m9"])
        #expect(change == .archive)
        #expect(!app.signals.bundles.contains { $0.id == "github" })
        #expect(app.signals.cleared == "GitHub, subscribed threads: marked 2 read.")
    }
}
