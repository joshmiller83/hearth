import Executor
import Foundation
import HearthKit
import HearthKitTestSupport
import NIOPosix
import RelayCore
import Testing
import Vapor
import VaporTesting

@testable import App

enum TestSupport {
    /// The relay runs on one event loop so SQLite gets one connection; tests do the same.
    static let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
}

/// Google, faked: canned calendar rows in, recorded writes out.
final class FakeGoogle: GoogleReader, GoogleWriter, @unchecked Sendable {
    private let lock = NSLock()
    var eventRows: [GmailkitEventRow] = FakeGoogle.defaultEventRows
    var calendarRows: [GmailkitCalendarRow] = [
        GmailkitCalendarRow(account: "sam@rivera.example", id: "primary", summary: "Sam Rivera", primary: true, access_role: "owner"),
        GmailkitCalendarRow(account: "robin@rivera.example", id: "primary", summary: "Robin", primary: true, access_role: "owner"),
    ]
    var failReads: (any Error)?
    var failWrites: (any Error)?
    private(set) var eventSweeps = 0
    private(set) var writes: [String] = []

    func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static let defaultEventRows: [GmailkitEventRow] = {
        let json = #"""
            [{"account": "sam@rivera.example", "calendar": "Sam Rivera", "calendar_id": "primary", "id": "huddle",
              "ical_uid": "huddle@x", "summary": "Leaders huddle", "start": "2026-10-29T19:00-04:00", "end": "2026-10-29T20:00-04:00",
              "all_day": false, "my_response": "needsAction", "attendees": [{"email": "sam@rivera.example"}], "meeting_links": []},
             {"account": "robin@rivera.example", "calendar": "Robin", "calendar_id": "primary", "id": "book",
              "summary": "book club", "start": "2026-10-26T18:30-04:00", "end": "2026-10-26T20:00-04:00", "location": "Library"},
             {"account": "sam@rivera.example", "calendar": "Sam Rivera", "calendar_id": "primary", "id": "far",
              "summary": "Far future", "start": "2026-12-20T10:00-05:00", "end": "2026-12-20T11:00-05:00"},
             {"account": "kid.rivera@example.com", "error": "[kid.rivera@example.com] invalid_grant"}]
            """#
        return try! HearthJSON.decode([GmailkitEventRow].self, from: Data(json.utf8))
    }()

    // MARK: GoogleReader

    func status() async -> BridgeStatus { BridgeStatus(state: .up) }
    func accounts() async throws -> [Account] { Fixtures.accounts }
    func aliases() async -> [String: String] {
        Dictionary(uniqueKeysWithValues: Fixtures.accounts.map { ($0.email.lowercased(), $0.alias) })
    }
    func calendars() async throws -> [GmailkitCalendarRow] {
        if let failReads { throw failReads }
        return calendarRows
    }
    func events(daysBack: Int, daysAhead: Int, limit: Int, zone: String) async throws -> [GmailkitEventRow] {
        if let failReads { throw failReads }
        withLock { eventSweeps += 1 }
        return eventRows
    }
    func search(query: String, account: String, limit: Int, metadataOnly: Bool) async throws -> [GmailkitMessageRow] { [] }
    func thread(id: String, account: String) async throws -> [GmailkitMessageRow] { [] }
    func labels(account: String) async throws -> [GmailkitLabelRow] { [] }

    // MARK: GoogleWriter

    private func record(_ line: String) throws {
        if let failWrites { throw failWrites }
        withLock { writes.append(line) }
    }

    func modify(account: String, messageIds: [String], change: MailChange) async throws -> JSONValue {
        try record("modify \(account) \(messageIds.joined(separator: ",")) \(change.verb)")
        return ["count": .int(messageIds.count)]
    }

    func reply(account: String, messageId: String, body: String, replyAll: Bool) async throws -> JSONValue {
        try record("reply \(account) \(messageId) \(body)")
        return ["id": "sent-1"]
    }

    func respond(account: String, calendarId: String, eventId: String, response: RSVP) async throws -> GmailkitEventRow {
        try record("respond \(account) \(calendarId) \(eventId) \(response.rawValue)")
        var row = FakeGoogle.defaultEventRows[0]
        row.my_response = response.rawValue
        return row
    }

    func createHold(account: String, title: String, start: Date, end: Date, notes: String?, zone: TimeZone) async throws -> GmailkitEventRow
    {
        try record("hold \(account) \(title) \(RFC3339.format(start, zone: zone))")
        return GmailkitEventRow(
            account: account, calendar: "primary", calendar_id: "primary", id: "hold-1", summary: title,
            start: RFC3339.format(start, zone: zone), end: RFC3339.format(end, zone: zone), all_day: false)
    }

    func deleteEvent(account: String, calendarId: String, eventId: String) async throws -> JSONValue {
        try record("delete \(account) \(calendarId) \(eventId)")
        return ["deleted": true]
    }
}

struct TestContext {
    let app: Application
    let clock: ManualClock
    let google: FakeGoogle

    /// A relay key that works on this app.
    func key(_ label: String = "test") async throws -> String {
        try await RelayKeys.issue(label: label, on: app.db, now: clock.now)
    }
}

/// Builds a relay on a fresh in-memory database with fake Google, runs `body`, and shuts it down.
func withTestApp<T>(
    clock: ManualClock = ManualClock(Fixtures.now),
    google: FakeGoogle = FakeGoogle(),
    adjust: (inout RelayConfig) -> Void = { _ in },
    _ body: (TestContext) async throws -> T
) async throws -> T {
    let app = try await Application.make(.testing, .shared(TestSupport.eventLoopGroup))
    var config = RelayConfig()
    config.database = .memory
    config.backupDirectory = NSTemporaryDirectory()
    config.now = { clock.now }
    let householdURL = FileManager.default.temporaryDirectory.appendingPathComponent("household-\(UUID().uuidString).json")
    try HearthJSON.encode(Fixtures.household).write(to: householdURL)
    config.householdFile = householdURL.path
    adjust(&config)
    let result: T
    do {
        try await configure(app, config: config, google: GoogleAccess(reader: google, writer: google))
        result = try await body(TestContext(app: app, clock: clock, google: google))
    } catch {
        try? await app.asyncShutdown()
        try? FileManager.default.removeItem(at: householdURL)
        throw error
    }
    try await app.asyncShutdown()
    try? FileManager.default.removeItem(at: householdURL)
    return result
}
