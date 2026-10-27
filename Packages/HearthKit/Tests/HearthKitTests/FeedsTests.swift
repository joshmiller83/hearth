import Foundation
import HearthKit
import HearthKitTestSupport
import Testing

@Suite("Feeds")
struct FeedsTests {
    let zone = Fixtures.household.zone
    var from: Date { Fixtures.at("2026-10-26T00:00") }
    var to: Date { Fixtures.at("2026-12-25T00:00") }

    static let calendar = """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        X-WR-CALNAME:Maple Grove Community Center\r
        BEGIN:VEVENT\r
        UID:craft@example.org\r
        DTSTART;TZID=America/New_York:20261107T100000\r
        DTEND;TZID=America/New_York:20261107T150000\r
        SUMMARY:Fall craft fair\r
        LOCATION:Main gym\\, Community center\r
        DESCRIPTION:Free admission.\\nVendors from all over the county\r
         and a bake sale.\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:movie@example.org\r
        DTSTART:20261113T233000Z\r
        DURATION:PT2H\r
        SUMMARY:Family movie night\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:closed@example.org\r
        DTSTART;VALUE=DATE:20261126\r
        SUMMARY:Closed for Thanksgiving\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:yoga@example.org\r
        DTSTART;TZID=America/New_York:20261027T090000\r
        DTEND;TZID=America/New_York:20261027T100000\r
        RRULE:FREQ=WEEKLY;BYDAY=TU,TH;COUNT=4\r
        SUMMARY:Chair yoga\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:cancelled@example.org\r
        DTSTART;TZID=America/New_York:20261110T180000\r
        STATUS:CANCELLED\r
        SUMMARY:Book sale\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:old@example.org\r
        DTSTART;TZID=America/New_York:20261001T180000\r
        SUMMARY:Last month\r
        END:VEVENT\r
        END:VCALENDAR\r
        """

    @Test func aCalendarFeedReads() throws {
        #expect(ICS.calendarName(Self.calendar) == "Maple Grove Community Center")
        let events = ICS.events(Self.calendar, feedId: "cc", zone: zone, from: from, to: to)
        #expect(
            events.map(\.title) == [
                "Chair yoga", "Chair yoga", "Chair yoga", "Chair yoga", "Fall craft fair", "Family movie night", "Closed for Thanksgiving",
            ])
        let fair = try #require(events.first { $0.title == "Fall craft fair" })
        #expect(fair.start == Fixtures.at("2026-11-07T10:00"))
        #expect(fair.end == Fixtures.at("2026-11-07T15:00"))
        #expect(fair.location == "Main gym, Community center")
        #expect(fair.summary == "Free admission.")
        #expect(fair.free)
        let movie = try #require(events.first { $0.title == "Family movie night" })
        #expect(movie.start == Fixtures.at("2026-11-13T18:30"))
        #expect(movie.end.timeIntervalSince(movie.start) == 7200)
        let closed = try #require(events.last)
        #expect(closed.isAllDay)
        #expect(closed.start == Fixtures.at("2026-11-26T00:00"))
        // Tuesday and Thursday, four times.
        #expect(
            events.filter { $0.title == "Chair yoga" }.map(\.start) == [
                Fixtures.at("2026-10-27T09:00"), Fixtures.at("2026-10-29T09:00"), Fixtures.at("2026-11-03T09:00"),
                Fixtures.at("2026-11-05T09:00"),
            ])
        #expect(Set(events.map(\.id)).count == events.count)
    }

    @Test func skipWordsLeaveEventsOut() {
        let feed = Feed(name: "Community center", kind: .ical, category: "family", skip: ["yoga", "senior lunch"], addedAt: Fixtures.now)
        let events = ICS.events(Self.calendar, feedId: feed.id, zone: zone, from: from, to: to)
        #expect(events.filter(feed.keeps).map(\.title) == ["Fall craft fair", "Family movie night", "Closed for Thanksgiving"])
        var checked = feed
        checked.checkedAt = Fixtures.now
        checked.total = 7
        checked.kept = 3
        #expect(checked.sub == "Calendar feed · 3 of 7 kept")
    }

    @Test func theRelayFetchesOnlyPublicAddresses() {
        func safe(_ text: String) -> String? { URL(string: text).flatMap(FeedAddress.safe)?.absoluteString }
        #expect(safe("https://calendar.example.org/events.ics") == "https://calendar.example.org/events.ics")
        #expect(safe("webcal://calendar.example.org/events.ics") == "https://calendar.example.org/events.ics")
        for blocked in [
            "http://calendar.example.org/e.ics", "https://localhost/e.ics", "https://192.168.1.10/e.ics", "https://10.6.5.88/e.ics",
            "https://router.local/e.ics", "https://[::1]/e.ics", "https://calendar.example.org:8080/e.ics", "https://nas.lan/e.ics",
            "file:///etc/hosts",
        ] {
            #expect(safe(blocked) == nil, "\(blocked) must be refused")
        }
    }

    @Test func pagesBecomeTextAndEvents() {
        let html = """
            <html><head><style>p { color: red }</style><script>alert("hi")</script></head>
            <body><h1>Events</h1><p>Tree lighting &amp; carols, Nov 27</p></body></html>
            """
        #expect(PageEventsPrompt.text(fromHTML: html) == "Events Tree lighting & carols, Nov 27")
        let reply = PageEventsPrompt.Reply(events: [
            .init(title: "Tree lighting", date: "2026-11-27", start: "18:00", end: "", location: "Market St", free: true, summary: ""),
            .init(title: "Parade", date: "2026-11-28", start: "", end: "", location: "", free: false, summary: "Floats and bands"),
            .init(title: "Old", date: "2026-10-01", start: "18:00", end: "", location: "", free: false, summary: ""),
        ])
        let events = PageEventsPrompt.events(reply, feedId: "borough", zone: zone, from: from, to: to)
        #expect(events.map(\.title) == ["Tree lighting", "Parade"])
        #expect(events[0].start == Fixtures.at("2026-11-27T18:00"))
        #expect(events[0].end == Fixtures.at("2026-11-27T19:00"))
        #expect(events[1].isAllDay)
    }

    @Test func theChatSearchesTheWebAndProposesFeeds() {
        let tools = FeedChatPrompt.tools()
        let request = ClaudeRequest(model: .opus, messages: [.user("Add the community center")], tools: tools)
        let json = request.body["tools"]?.arrayValue ?? []
        #expect(json[0] == ["type": "web_search_20260209", "name": "web_search", "max_uses": 5])
        #expect(json[1]["type"]?.stringValue == "web_fetch_20260209")
        #expect(json[3]["strict"] == true)
        let input: JSONValue = [
            "name": "Community center", "kind": "ical", "url": "webcal://calendar.example.org/cc.ics", "category": "family",
            "skip": ["Yoga", "senior lunch"], "kept": 3, "total": 14,
        ]
        let proposal = FeedChatPrompt.proposal(input)
        #expect(proposal?.feed.url?.absoluteString == "https://calendar.example.org/cc.ics")
        #expect(proposal?.feed.skip == ["yoga", "senior lunch"])
        #expect(proposal?.kept == 3)
        var local = input
        if case .object(var object) = local {
            object["url"] = "https://192.168.1.2/cc.ics"
            local = .object(object)
        }
        #expect(FeedChatPrompt.proposal(local) == nil)
    }

    @Test func facebookRulesKeepWhatMatters() {
        let reply = FacebookRulesPrompt.Reply(
            reply: "I'll keep the family group and Mom, plus invites and birthdays.", keep: ["Rivera Family", "Carol Rivera"],
            invitesAndBirthdays: true)
        let rules = FacebookRulesPrompt.rules(reply)
        #expect(rules.map(\.id) == ["facebook-keep", "facebook-rest"])
        let mail = [
            Fixtures.mail("f1", "home", "Facebook <notification@facebookmail.com>", "New post in Rivera Family", "", "2026-10-25T09:00"),
            Fixtures.mail(
                "f2", "home", "Facebook <notification@facebookmail.com>", "Carol Rivera commented on your photo", "", "2026-10-24T09:00"),
            Fixtures.mail("f3", "home", "Facebook <notification@facebookmail.com>", "Pat invited you to an event", "", "2026-10-23T09:00"),
            Fixtures.mail(
                "f4", "home", "Facebook <notification@facebookmail.com>", "Deals on Marketplace near you", "", "2026-10-22T09:00"),
            Fixtures.mail("f5", "home", "Facebook <notification@facebookmail.com>", "Old news in Rivera Family", "", "2026-10-01T09:00"),
        ]
        let preview = FacebookRulesPrompt.preview(rules, mail: mail, now: Fixtures.now)
        #expect(preview.kept == 3)
        #expect(preview.total == 4)
    }
}
