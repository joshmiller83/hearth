import Fluent
import Foundation
import HearthKit
import Logging
import RelayCore

/// Every 30 minutes: the National Weather Service's alerts for home, and the
/// coming night's low (frost). Severe alerts are pushed once, even at night.
public struct WeatherJob: RelayJob {
    /// The weather service asks callers to say who they are.
    public static let userAgent = "hearth-relay (https://github.com/joshmiller83/hearth)"

    public let name = "weather"
    public let schedule = JobSchedule.every(30 * 60)

    public init() {}

    public func run(_ context: JobContext) async throws {
        _ = try await Self.check(context)
    }

    @discardableResult
    public static func check(_ context: JobContext) async throws -> RelaySignals {
        let cache = context.cache
        let now = context.now()
        guard let http = context.http, let point = Signals.point(context.household) else {
            let none = RelaySignals(
                signals: [], fetchedAt: now, problems: [SourceProblem(source: "weather", message: "No home location in household.json.")])
            try await cache.set(none, Cache.signals, now: now)
            return none
        }
        var problems: [SourceProblem] = []
        func get(_ url: String) async -> JSONValue? {
            guard let address = URL(string: url) else { return nil }
            let request = HTTPRequest(url: address, headers: ["User-Agent": userAgent, "Accept": "application/geo+json"], timeout: 20)
            do {
                let response = try await http.send(request)
                guard response.status == 200 else {
                    problems.append(SourceProblem(source: "weather", message: "The weather service answered \(response.status)."))
                    return nil
                }
                return try JSONValue.parse(response.body)
            } catch {
                problems.append(SourceProblem(source: "weather", message: "Couldn't reach the weather service: \(error)"))
                return nil
            }
        }

        let alerts = await get("https://api.weather.gov/alerts/active?point=\(point)")
        var forecastURL = try await cache.get(String.self, Cache.forecastURL)
        if forecastURL == nil, let points = await get("https://api.weather.gov/points/\(point)") {
            forecastURL = points["properties"]?["forecast"]?.stringValue
            if let forecastURL { try await cache.set(forecastURL, Cache.forecastURL, now: now) }
        }
        let forecast = await forecastURL.asyncMap { await get($0) } ?? nil
        let signals = Signals.weather(alerts: alerts, forecast: forecast, household: context.household, now: now)
        let report = RelaySignals(signals: signals, fetchedAt: now, problems: problems)
        try await cache.set(report, Cache.signals, now: now)

        // What's pressing goes out as a push, once, through quiet hours.
        let urgent = signals.filter { $0.priority >= 2 }
        if !urgent.isEmpty {
            var pushed = try await cache.get([String].self, Cache.signalsPushed) ?? []
            let rules = try await cache.get(PhoneContext.self, Cache.context)?.rules ?? HouseRules()
            for signal in urgent where !pushed.contains(signal.id) {
                let alert = PushAlert(title: signal.title, body: signal.detail, kind: "weather", urgency: .urgent)
                try await PushQueue.enqueue(alert, quietHours: rules.quietHours, zone: context.household.zone, now: now, db: context.db)
                pushed.append(signal.id)
            }
            try await cache.set(Array(pushed.suffix(50)), Cache.signalsPushed, now: now)
        }
        context.logger.info("weather: \(signals.count) signal\(signals.count == 1 ? "" : "s"), \(problems.count) problems")
        return report
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
