import Foundation
import HearthKit
import RelayCore

/// The writes Hearth makes to Google, one typed method per kind of action.
/// Arguments are built here, never passed through from a request, so nothing
/// can smuggle in a file path or a permanent delete.
public protocol GoogleWriter: Sendable {
    func modify(account: String, messageIds: [String], change: MailChange) async throws -> JSONValue
    func reply(account: String, messageId: String, body: String, replyAll: Bool) async throws -> JSONValue
    func respond(account: String, calendarId: String, eventId: String, response: RSVP) async throws -> GmailkitEventRow
    func createHold(account: String, title: String, start: Date, end: Date, notes: String?, zone: TimeZone) async throws -> GmailkitEventRow
    func deleteEvent(account: String, calendarId: String, eventId: String) async throws -> JSONValue
}

/// `GoogleWriter` over the gmailkit bridge.
public struct GmailkitWriter: GoogleWriter {
    let bridge: GmailkitBridge

    public init(bridge: GmailkitBridge) {
        self.bridge = bridge
    }

    public func modify(account: String, messageIds: [String], change: MailChange) async throws -> JSONValue {
        try await bridge.callWrite(
            "gmail_modify_batch",
            [
                "message_ids": .array(messageIds.map { .string($0) }),
                "account": .string(account),
                "add_labels": .array(change.addLabels.map { .string($0) }),
                "remove_labels": .array(change.removeLabels.map { .string($0) }),
                "archive": .bool(change.archive),
                "trash": .bool(change.trash),
                "mark_read": .bool(change.markRead),
            ])
    }

    public func reply(account: String, messageId: String, body: String, replyAll: Bool) async throws -> JSONValue {
        try await bridge.callWrite(
            "gmail_reply",
            [
                "message_id": .string(messageId), "account": .string(account), "body": .string(body), "reply_all": .bool(replyAll),
            ])
    }

    public func respond(account: String, calendarId: String, eventId: String, response: RSVP) async throws -> GmailkitEventRow {
        try await bridge.callWrite(
            "gmail_calendar_respond",
            [
                "event_id": .string(eventId), "account": .string(account), "response": .string(response.rawValue),
                "calendar_id": .string(calendarId), "notify": true,
            ]
        ).decode(GmailkitEventRow.self)
    }

    public func createHold(account: String, title: String, start: Date, end: Date, notes: String?, zone: TimeZone) async throws
        -> GmailkitEventRow
    {
        var arguments: JSONObject = [
            "account": .string(account),
            "summary": .string(title),
            "start": .string(RFC3339.format(start, zone: zone)),
            "end": .string(RFC3339.format(end, zone: zone)),
            "calendar_id": "primary",
            // A private hold: no guests, nobody emailed.
            "notify": false,
            "timezone": .string(zone.identifier),
        ]
        if let notes, !notes.isEmpty { arguments["description"] = .string(notes) }
        return try await bridge.callWrite("gmail_calendar_create_event", .object(arguments)).decode(GmailkitEventRow.self)
    }

    public func deleteEvent(account: String, calendarId: String, eventId: String) async throws -> JSONValue {
        try await bridge.callWrite(
            "gmail_calendar_delete_event",
            [
                "event_id": .string(eventId), "account": .string(account), "calendar_id": .string(calendarId), "notify": false,
            ])
    }
}
