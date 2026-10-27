import Foundation
import HearthKit
import HearthKitTestSupport
import Jobs
import Testing
import Vapor

@testable import App
@testable import RelayCore

@Suite("Event feeds")
struct FeedsRouteTests {
    static let ics = """
        BEGIN:VCALENDAR
        X-WR-CALNAME:Maple Grove Community Center
        BEGIN:VEVENT
        UID:craft@example.org
        DTSTART;TZID=America/New_York:20261107T100000
        DTEND;TZID=America/New_York:20261107T150000
        SUMMARY:Fall craft fair
        DESCRIPTION:Free admission
        END:VEVENT
        BEGIN:VEVENT
        UID:yoga@example.org
        DTSTART;TZID=America/New_York:20261105T090000
        SUMMARY:Chair yoga
        END:VEVENT
        END:VCALENDAR
        """

    static func calendar() -> ScriptedTransport.Reply {
        .response(HTTPResponse(status: 200, headers: ["content-type": "text/calendar"], body: Data(ics.utf8)))
    }

    @Test func aFeedIsPreviewedThenAddedWithItsSkipWords() async throws {
        let http = ScriptedTransport([Self.calendar(), Self.calendar()])
        try await withTestApp(http: http) { t in
            let key = try await t.key()
            let preview = try await t.app.client2.send(
                .POST, RelayPath.feeds + "/preview", key: key,
                json: FeedPreviewRequest(url: URL(string: "webcal://calendar.example.org/cc.ics")!)
            ).decode(FeedPreview.self)
            #expect(preview.name == "Maple Grove Community Center")
            #expect(preview.events.map(\.title) == ["Chair yoga", "Fall craft fair"])
            #expect(http.requests.first?.url.absoluteString == "https://calendar.example.org/cc.ics")

            let added = try await t.app.client2.send(
                .POST, RelayPath.feeds, key: key,
                json: NewFeed(
                    name: "Community center", kind: .ical, url: URL(string: "https://calendar.example.org/cc.ics"), category: "family",
                    skip: ["yoga"]))
            #expect(added.status == .created)
            let feeds = try added.decode(FeedsResponse.self)
            #expect(feeds.events.map(\.title) == ["Fall craft fair"])
            #expect(feeds.feeds.first?.sub == "Calendar feed · 1 of 2 kept")

            let id = try #require(feeds.feeds.first?.id)
            let removed = try await t.app.client2.send(.DELETE, RelayPath.feeds + "/" + id, key: key).decode(FeedsResponse.self)
            #expect(removed.feeds.isEmpty)
            #expect(removed.events.isEmpty)
        }
    }

    @Test func onlyPublicAddresses() async throws {
        try await withTestApp { t in
            let key = try await t.key()
            for address in ["https://192.168.1.20/cal.ics", "https://nas.local/cal.ics", "http://calendar.example.org/cal.ics"] {
                let preview = try await t.app.client2.send(
                    .POST, RelayPath.feeds + "/preview", key: key, json: FeedPreviewRequest(url: URL(string: address)!))
                #expect(preview.status == .badRequest, "\(address) must be refused")
                let add = try await t.app.client2.send(
                    .POST, RelayPath.feeds, key: key, json: NewFeed(name: "LAN", kind: .ical, url: URL(string: address)!, category: "x"))
                #expect(add.status == .badRequest)
            }
            #expect(try await t.app.client2.send(.GET, RelayPath.feeds).status == .unauthorized)
        }
    }

    @Test func claudeReadsPagesOnMondays() async throws {
        let html = "<html><body><h2>Borough events</h2><p>Tree lighting, Nov 27, 6 PM, Market St. Free!</p></body></html>"
        let http = ScriptedTransport([.response(HTTPResponse(status: 200, body: Data(html.utf8)))])
        let reply = PageEventsPrompt.Reply(events: [
            .init(title: "Tree lighting", date: "2026-11-27", start: "18:00", end: "", location: "Market St", free: true, summary: "")
        ])
        let claude = ClaudeClient(
            apiKey: "k",
            transport: ScriptedTransport([ScriptedTransport.message(text: String(decoding: try HearthJSON.encode(reply), as: UTF8.self))]),
            pause: { _ in })
        try await withTestApp(claude: claude, http: http) { t in
            let key = try await t.key()
            let added = try await t.app.client2.send(
                .POST, RelayPath.feeds, key: key,
                json: NewFeed(
                    name: "Borough events page", kind: .page, url: URL(string: "https://borough.example.gov/events"), category: "family")
            ).decode(FeedsResponse.self)
            #expect(added.events.map(\.title) == ["Tree lighting"])
            #expect(added.events.first?.free == true)
            #expect(added.feeds.first?.sub == "No feed, so Claude reads it Mondays · 1 kept")
        }
    }

    @Test func withoutTheRelaysClaudeAPageWaits() async throws {
        try await withTestApp { t in
            let added = try await t.app.client2.send(
                .POST, RelayPath.feeds, key: try await t.key(),
                json: NewFeed(name: "Borough", kind: .page, url: URL(string: "https://borough.example.gov/events"), category: "family")
            ).decode(FeedsResponse.self)
            #expect(added.feeds.first?.problem == "reading it needs the relay's Claude key")
        }
    }
}
