import Foundation
import HearthKit

/// Read-only Google access: everything the timed jobs and Ask's tool proxy get.
/// There are no write methods here by design; writes live in the Executor module.
public protocol GoogleReader: Sendable {
    func status() async -> BridgeStatus
    func accounts() async throws -> [Account]
    /// gmailkit's account email (lowercased) → alias.
    func aliases() async -> [String: String]
    func calendars() async throws -> [GmailkitCalendarRow]
    func events(daysBack: Int, daysAhead: Int, limit: Int, zone: String) async throws -> [GmailkitEventRow]
    func search(query: String, account: String, limit: Int, metadataOnly: Bool) async throws -> [GmailkitMessageRow]
    func thread(id: String, account: String) async throws -> [GmailkitMessageRow]
    func labels(account: String) async throws -> [GmailkitLabelRow]
}

/// `GoogleReader` over the gmailkit bridge.
public struct GmailkitReader: GoogleReader {
    let bridge: GmailkitBridge

    public init(bridge: GmailkitBridge) {
        self.bridge = bridge
    }

    public func status() async -> BridgeStatus { await bridge.status() }

    public func accounts() async throws -> [Account] {
        let known = await bridge.knownAccounts()
        return known.isEmpty ? try await bridge.refreshAccounts() : known
    }

    public func aliases() async -> [String: String] {
        if await bridge.knownAccounts().isEmpty { _ = try? await bridge.refreshAccounts() }
        return await bridge.aliasMap()
    }

    public func calendars() async throws -> [GmailkitCalendarRow] {
        try await bridge.callRead("gmail_calendars", ["account": "all"]).decode([GmailkitCalendarRow].self)
    }

    public func events(daysBack: Int, daysAhead: Int, limit: Int, zone: String) async throws -> [GmailkitEventRow] {
        try await bridge.callRead(
            "gmail_calendar_events",
            [
                "account": "all", "days_back": .int(daysBack), "days_ahead": .int(daysAhead),
                "limit": .int(limit), "timezone": .string(zone),
            ]
        ).decode([GmailkitEventRow].self)
    }

    public func search(query: String, account: String, limit: Int, metadataOnly: Bool) async throws -> [GmailkitMessageRow] {
        try await bridge.callRead(
            "gmail_search",
            [
                "query": .string(query), "account": .string(account), "limit": .int(limit), "metadata_only": .bool(metadataOnly),
            ]
        ).decode([GmailkitMessageRow].self)
    }

    public func thread(id: String, account: String) async throws -> [GmailkitMessageRow] {
        try await bridge.callRead("gmail_thread", ["thread_id": .string(id), "account": .string(account)]).decode([GmailkitMessageRow].self)
    }

    public func labels(account: String) async throws -> [GmailkitLabelRow] {
        try await bridge.callRead("gmail_labels", ["account": .string(account)]).decode([GmailkitLabelRow].self)
    }
}
