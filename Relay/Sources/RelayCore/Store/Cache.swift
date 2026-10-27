import Fluent
import Foundation
import HearthKit

/// Typed access to the cache table: one Codable value per key.
public struct Cache: Sendable {
    public static let events = "calendar.events"
    public static let mailSnapshot = "mail.snapshot"
    /// Account alias → (label id → name), refreshed daily.
    public static let mailLabels = "mail.labels"
    /// Mail rules the owner edited on the phone (defaults when absent).
    public static let mailRules = "mail.rules"
    public static let brief = "brief"
    public static let context = "phone.context"
    public static let signals = "signals"
    /// The weather service's forecast address for home (it rarely changes).
    public static let forecastURL = "weather.forecastURL"
    /// Signals already pushed, so each goes out once.
    public static let signalsPushed = "signals.pushed"
    /// The event feeds, and the events they hold.
    public static let feeds = "feeds"
    public static let feedEvents = "feeds.events"

    public let db: any Database

    public init(db: any Database) {
        self.db = db
    }

    public func get<T: Decodable>(_ type: T.Type, _ key: String) async throws -> T? {
        guard let entry = try await CacheEntryModel.find(key, on: db) else { return nil }
        return try HearthJSON.decode(T.self, from: Data(entry.json.utf8))
    }

    public func updatedAt(_ key: String) async throws -> Date? {
        try await CacheEntryModel.find(key, on: db)?.updatedAt
    }

    public func set(_ value: some Encodable, _ key: String, now: Date) async throws {
        let json = String(decoding: try HearthJSON.encode(value), as: UTF8.self)
        if let entry = try await CacheEntryModel.find(key, on: db) {
            entry.json = json
            entry.updatedAt = now
            try await entry.update(on: db)
        } else {
            try await CacheEntryModel(key: key, json: json, updatedAt: now).create(on: db)
        }
    }
}
