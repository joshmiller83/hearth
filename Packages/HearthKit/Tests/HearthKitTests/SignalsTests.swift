import Foundation
import HearthKitTestSupport
import Testing

@testable import HearthKit

@Suite("Signals")
struct SignalsTests {
    let household = Fixtures.household

    /// The fixture inbox, sorted the way the relay sorts it with no Claude key.
    var snapshot: MailSnapshot {
        let items = Fixtures.inbox.map {
            MailRules.classify($0, rules: MailRules.defaults, labelNames: [:], now: Fixtures.now)
                ?? TriagedMail(item: $0, queue: nil, tag: "Needs a look", reason: "No rule matched", sortedBy: .rule("test"))
        }
        return MailSnapshot(generatedAt: Fixtures.now, accounts: ["home", "work"], items: items, newCount: items.count, jobHuntLabels: [:])
    }

    @Test func mailBecomesSignalsAndQuietBundles() {
        let (signals, bundles) = Signals.fromMail(snapshot, household: household, now: Fixtures.now)
        let github = signals.first { $0.monogram == "GH" }
        #expect(github?.title == "Review requested on #218")
        #expect(github?.source == "GitHub · via home")
        #expect(github?.category == .work)
        #expect(signals.first { $0.title == "Thanksgiving plans??" }?.category == .family)
        #expect(signals.first { $0.title == "Trunk or Treat shifts" }?.category == .church)
        #expect(Set(bundles.map(\.id)) == ["github", "promotions", "newsletters", "shipping"])
        let quiet = bundles.first { $0.id == "github" }
        #expect(quiet?.detail == "2 updates")
        if case .markRead(_, let mail) = quiet?.action {
            #expect(Set(mail.map(\.messageId)) == ["m8", "m9"])
        } else {
            Issue.record("GitHub chatter should be marked read in one tap")
        }
        #expect(bundles.first { $0.id == "promotions" }?.detail == "1 across 1 inbox · 1 queued for delete")
        #expect(bundles.first { $0.id == "shipping" }?.detail == "1 update · nothing late")
    }

    @Test func pressingParcelsAndFacebookEventsStandOut() {
        let items = [
            Fixtures.mail(
                "p1", "home", "UPS <mcinfo@ups.com>", "Out for delivery today", "Your package arrives by 7 PM.", "2026-10-26T07:00"),
            Fixtures.mail(
                "f1", "home", "Facebook <notification@facebookmail.com>", "New event in Rivera Family: Thanksgiving potluck",
                "Sat, Nov 28.", "2026-10-26T06:00"),
            Fixtures.mail("f2", "home", "Facebook <notification@facebookmail.com>", "Pat liked your photo", "", "2026-10-26T05:00"),
            Fixtures.mail(
                "pc", "home", "Planning Center <noreply@planningcenteronline.com>", "Scheduling request: greeter, Sun Nov 1",
                "Please accept or decline.", "2026-10-26T04:00"),
        ].map { TriagedMail(item: $0, queue: .archive, tag: "Social", reason: "", sortedBy: .rule("test")) }
        let mail = MailSnapshot(generatedAt: Fixtures.now, accounts: ["home"], items: items, newCount: 4, jobHuntLabels: [:])
        let (signals, bundles) = Signals.fromMail(mail, household: household, now: Fixtures.now)
        #expect(signals.map(\.monogram).sorted() == ["FB", "PC", "U"])
        #expect(signals.first { $0.monogram == "PC" }?.category == .church)
        #expect(bundles.map(\.id) == ["facebook"])
    }

    @Test func gitHubSubjectsComeApart() {
        let pr = GitHubSubject("Re: [acme/site] Fix the header (PR #412)")
        #expect(pr.repo == "acme/site")
        #expect(pr.title == "Fix the header")
        #expect(pr.number == 412)
        #expect(pr.isPullRequest)
        #expect(pr.url?.absoluteString == "https://github.com/acme/site/issues/412")
        let issue = GitHubSubject("[acme/site] Crash on save (Issue #45)")
        #expect(issue.number == 45)
        #expect(!issue.isPullRequest)
        let bare = GitHubSubject("[module] Review requested on #218")
        #expect(bare.number == 218)
        #expect(bare.url == nil)
        #expect(bare.repoName == "module")
    }

    static let frostAdvisory: JSONValue = [
        "type": "FeatureCollection",
        "features": [
            [
                "properties": [
                    "event": "Frost Advisory", "severity": "Minor", "status": "Actual", "messageType": "Alert",
                    "onset": "2026-10-27T01:00:00-04:00", "ends": "2026-10-27T09:00:00-04:00",
                    "instruction": "Take steps now to protect tender plants from the cold. Cover them.",
                ]
            ],
            [
                "properties": [
                    "event": "Wind Advisory", "severity": "Moderate", "status": "Actual", "messageType": "Alert",
                    "onset": "2026-10-25T01:00:00-04:00", "ends": "2026-10-25T09:00:00-04:00",
                ]
            ],
        ],
    ]

    static func night(_ temperature: Int) -> JSONValue {
        [
            "properties": [
                "periods": [
                    [
                        "name": "Tonight", "startTime": "2026-10-26T18:00:00-04:00", "isDaytime": false, "temperature": .int(temperature),
                        "temperatureUnit": "F",
                    ]
                ]
            ]
        ]
    }

    @Test func alertsBecomeSignalsAndOldOnesDrop() throws {
        let signals = Signals.weather(alerts: Self.frostAdvisory, forecast: Self.night(29), household: household, now: Fixtures.now)
        // The expired wind advisory is gone, and the alert already says frost.
        #expect(signals.count == 1)
        let frost = try #require(signals.first)
        #expect(frost.title == "Frost Advisory until Tue 9:00 AM")
        #expect(frost.detail == "Maple Grove. Take steps now to protect tender plants from the cold.")
        #expect(frost.priority == 1)
        #expect(
            frost.actions.first == .remind(label: "Remind me at 5", title: "Cover the tender plants", at: Fixtures.at("2026-10-26T17:00")))
    }

    @Test func aFreezingNightWarnsWithoutAnAlert() throws {
        let frost = try #require(Signals.weather(alerts: nil, forecast: Self.night(29), household: household, now: Fixtures.now).first)
        #expect(frost.title == "Frost tonight, low of 29°F")
        #expect(frost.detail == "Maple Grove. Cover anything tender before sundown.")
        #expect(Signals.weather(alerts: nil, forecast: Self.night(41), household: household, now: Fixtures.now).isEmpty)
        // Too late in the day for a 5 PM reminder.
        let evening = Signals.weather(alerts: nil, forecast: Self.night(29), household: household, now: Fixtures.at("2026-10-26T17:30"))
        #expect(evening.first?.actions.contains { if case .remind = $0 { true } else { false } } == false)
    }

    @Test func severeWeatherIsPressing() {
        let warning: JSONValue = [
            "features": [
                [
                    "properties": [
                        "event": "Severe Thunderstorm Warning", "severity": "Severe", "onset": "2026-10-26T10:00:00-04:00",
                        "ends": "2026-10-26T11:00:00-04:00", "description": "* WHAT...60 mph wind gusts.",
                    ]
                ]
            ]
        ]
        let signal = Signals.weather(alerts: warning, forecast: nil, household: household, now: Fixtures.now).first
        #expect(signal?.priority == 2)
        #expect(signal?.title == "Severe Thunderstorm Warning until 11:00 AM")
        #expect(signal?.detail == "Maple Grove. WHAT...60 mph wind gusts.")
    }

    @Test func theWeatherPointIsAboutAKilometer() {
        var home = household
        home.latitude = 40.2142
        home.longitude = -77.0086
        #expect(Signals.point(home) == "40.21,-77.01")
    }

    @Test func theSummaryCountsTheNight() {
        let line = Signals.summary(mail: snapshot, worth: 4, household: household, quiet: QuietHours(), now: Fixtures.now)
        let overnight = snapshot.items.filter { $0.item.date >= Fixtures.at("2026-10-25T21:00") }
        #expect(line.hasPrefix("\(overnight.count) notifications since 9 PM, from "))
        #expect(line.hasSuffix("Four are worth a look."))
        #expect(
            Signals.since(now: Fixtures.at("2026-10-26T22:00"), quiet: QuietHours(), zone: household.zone)
                == Fixtures.at("2026-10-26T21:00"))
    }

    @Test func pressingFirstThenNewest() {
        func signal(_ id: String, _ priority: Int, _ local: String) -> Signal {
            Signal(
                id: id, category: .family, monogram: "X", source: "", date: Fixtures.at(local), title: id, detail: "", priority: priority)
        }
        let order = Signals.sorted([
            signal("a", 1, "2026-10-26T08:00"), signal("b", 2, "2026-10-25T08:00"), signal("c", 1, "2026-10-26T09:00"),
        ])
        #expect(order.map(\.id) == ["b", "c", "a"])
    }
}
