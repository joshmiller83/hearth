import Foundation
import HearthKit
import HearthKitTestSupport
import Jobs
import Testing
import Vapor

@testable import App
@testable import RelayCore

@Suite("Weather")
struct WeatherTests {
    static let warning: JSONValue = [
        "features": [
            [
                "properties": [
                    "event": "Severe Thunderstorm Warning", "severity": "Severe", "status": "Actual", "messageType": "Alert",
                    "onset": "2026-10-26T10:00:00-04:00", "ends": "2026-10-26T11:00:00-04:00", "instruction": "Move indoors now.",
                ]
            ]
        ]
    ]
    static let points: JSONValue = ["properties": ["forecast": "https://api.weather.gov/gridpoints/CTP/1,2/forecast"]]
    static let mild: JSONValue = [
        "properties": [
            "periods": [
                [
                    "name": "Tonight", "startTime": "2026-10-26T18:00:00-04:00", "isDaytime": false, "temperature": 41,
                    "temperatureUnit": "F",
                ]
            ]
        ]
    ]

    @Test func severeWeatherIsPushedOnce() async throws {
        let http = ScriptedTransport([
            ScriptedTransport.json(200, Self.warning.serialized()), ScriptedTransport.json(200, Self.points.serialized()),
            ScriptedTransport.json(200, Self.mild.serialized()),
            ScriptedTransport.json(200, Self.warning.serialized()), ScriptedTransport.json(200, Self.mild.serialized()),
        ])
        try await withTestApp(http: http) { t in
            let key = try await t.key()
            let ran = await t.app.relay.jobs.run(named: "weather", t.app.jobContext())
            #expect(ran)
            let signals = try await t.app.client2.send(.GET, RelayPath.signals, key: key).decode(RelaySignals.self)
            #expect(signals.signals.map(\.title) == ["Severe Thunderstorm Warning until 11:00 AM"])
            #expect(signals.signals.first?.priority == 2)
            #expect(try await PushModel.query(on: t.app.db).count() == 1)

            // The next check pushes nothing new and reuses the forecast address.
            t.clock.advance(30 * 60)
            _ = await t.app.relay.jobs.run(named: "weather", t.app.jobContext())
            #expect(try await PushModel.query(on: t.app.db).count() == 1)
            #expect(
                http.requests.map(\.url.path) == [
                    "/alerts/active", "/points/40.21,-77.0", "/gridpoints/CTP/1,2/forecast", "/alerts/active",
                    "/gridpoints/CTP/1,2/forecast",
                ])
            #expect(http.requests.first?.headers["User-Agent"] == WeatherJob.userAgent)
        }
    }

    @Test func signalsNeedAKeyAndStartEmpty() async throws {
        try await withTestApp { t in
            let none = try await t.app.client2.send(.GET, RelayPath.signals)
            #expect(none.status == .unauthorized)
            let empty = try await t.app.client2.send(.GET, RelayPath.signals, key: try await t.key()).decode(RelaySignals.self)
            #expect(empty.signals.isEmpty)
            // When the weather service can't be reached, the phone hears why.
            let checked = try await t.app.client2.send(.GET, RelayPath.signals + "?refresh=1", key: try await t.key()).decode(
                RelaySignals.self)
            #expect(checked.problems.first?.source == "weather")
        }
    }
}
