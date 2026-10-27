import Foundation
import HearthKit
import HearthKitTestSupport
import Testing

@testable import HearthCore

@Suite("Around town")
@MainActor
struct TownModelTests {
    func loaded() async -> (AppModel, AppServices) {
        let services = AppServices.fixtures(waits: false)
        let app = AppModel(services: services)
        await app.refreshAll()
        return (app, services)
    }

    @Test func eventsMatchedToOpenEvenings() async throws {
        let (app, _) = await loaded()
        let town = app.town
        #expect(town.chips.map(\.label) == ["For you two", "Church", "Family", "Tech", "Free"])
        // Skip words keep the library's storytime out.
        #expect(!town.events.contains { $0.title == "Toddler storytime" })
        let author = try #require(town.events.first { $0.title == "Author talk at the public library" })
        #expect(town.fits(author))
        #expect(town.why(author) == "Public library · free · Thursday evening is open")
        #expect(town.place(author) == "Main branch · 7–8 PM")
        #expect(town.featured?.title == "Last farmers market of the season")
        town.filter = .category("church")
        #expect(town.shown.map(\.title) == ["Trunk or Treat", "Fall harvest dinner"])
        town.filter = .free
        #expect(town.shown.allSatisfy { $0.free })
    }

    @Test func anEventThatIsntForThemIsHidden() async throws {
        let (app, services) = await loaded()
        let town = app.town
        let market = try #require(town.featured)
        town.hide(market)
        #expect(town.featured?.id != market.id)
        #expect(!town.shown.contains(market))
        #expect(town.hiddenCount == 1)
        town.undoHide()
        #expect(town.featured == market)
        town.hide(market)
        // Remembered across launches; put back on request.
        let again = AppModel(services: services)
        #expect(again.town.hidden == [market.id])
        again.town.showHidden()
        #expect(again.town.hiddenCount == 0)
    }

    @Test func anEventGoesOnTheFamilyCalendarAndComesOff() async throws {
        let (app, services) = await loaded()
        let town = app.town
        let author = try #require(town.events.first { $0.title == "Author talk at the public library" })
        await town.toggle(author)
        let calendar = services.calendar as! FixtureCalendar
        #expect(calendar.events.map(\.title) == ["Author talk at the public library"])
        #expect(town.isAdded(author))
        await town.toggle(author)
        #expect(calendar.events.isEmpty)
        #expect(!town.isAdded(author))
        #expect(town.shareText(author) == "Author talk at the public library: Thu, Nov 5, 7:00–8:00 PM at Main branch. Want to go?")
    }

    @Test func claudeFindsAFeedAndItsKeptEvents() async throws {
        let (app, _) = await loaded()
        let town = app.town
        await town.send("The community center has a calendar online somewhere. Can you add it?")
        #expect(town.chatPhase == .idle)
        #expect(town.chat.map(\.fromOwner) == [true, false])
        #expect(town.chat.last?.text.hasPrefix("Found it.") == true)
        let proposal = try #require(town.proposal)
        #expect(proposal.kept == 3)
        #expect(proposal.total == 14)
        #expect(proposal.feed.skip == ["yoga", "fitness", "senior lunch"])

        await town.addProposed(keepAll: false)
        #expect(town.addedFeed?.note == "Added the community center feed, 3 of 14 kept")
        #expect(town.feeds.last?.name == "Community center")
        #expect(town.events.contains { $0.title == "Fall craft fair" })
        #expect(!town.events.contains { $0.title == "Chair yoga" })

        await town.undoAdd()
        #expect(!town.feeds.contains { $0.name == "Community center" })
        #expect(!town.events.contains { $0.title == "Fall craft fair" })

        // The next message pays the result owed for the proposal.
        await town.send("Thanks. Anything at the library?")
        let opening = try #require(
            town.transcript.first { $0.role == .user && $0.content.first?.type == "tool_result" && $0.content.last?.type == "text" })
        #expect(opening.content[0].json["tool_use_id"]?.stringValue == "toolu_feed")
    }

    @Test func facebookRulesFromWhatTheOwnerSays() async throws {
        let (app, _) = await loaded()
        let facebook = app.facebook
        await facebook.refresh()
        #expect(facebook.week.count == 4)
        #expect(facebook.events.map(\.subject) == ["New event in Rivera Family: Thanksgiving potluck"])
        #expect(facebook.keptThisWeek == 0)
        await facebook.tell("Only the family group and anything from Lou. Skip Marketplace.")
        let proposal = try #require(facebook.proposal)
        #expect(proposal.kept == 2)
        #expect(proposal.total == 4)
        facebook.save()
        #expect(app.mailRules.prefix(2).map(\.id) == ["facebook-keep", "facebook-rest"])
        #expect(facebook.keptThisWeek == 2)
        #expect(
            FacebookModel.chips(facebook.rules) == [
                "Keep: Rivera Family", "Keep: Lou Rivera", "Keep: invites, birthdays", "Archive: the rest",
            ])

        let potluck = try #require(facebook.events.first)
        await facebook.capture(potluck)
        #expect(app.capture.noteText.contains("Thanksgiving potluck"))
    }
}
