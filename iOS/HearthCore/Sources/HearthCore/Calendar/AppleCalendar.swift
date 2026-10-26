import EventKit
import Foundation
import HearthKit

/// The phone's own calendars (iCloud Family, Birthdays, Reminders) through EventKit.
/// Google calendars come from the relay instead, so calendars from Google
/// accounts on the phone are left out by default to avoid reading them twice.
public protocol AppleCalendar: Sendable {
    func access() -> CalendarAccess
    func requestAccess() async -> CalendarAccess
    func calendars() async -> [AppleCalendarInfo]
    func events(from: Date, to: Date, calendarIds: Set<String>?) async -> [AgendaEvent]
    /// Yields whenever the calendar database changes (another app, iCloud sync).
    func changes() -> AsyncStream<Void>
}

public enum CalendarAccess: String, Sendable, Equatable {
    case notDetermined
    case denied
    case writeOnly
    case full
}

public struct AppleCalendarInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var source: String
    public var isICloud: Bool
    public var isBirthdays: Bool
    public var isSubscribed: Bool
    public var isGoogle: Bool
    public var allowsModifications: Bool

    public init(
        id: String, title: String, source: String, isICloud: Bool, isBirthdays: Bool = false, isSubscribed: Bool = false,
        isGoogle: Bool = false, allowsModifications: Bool = true
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.isICloud = isICloud
        self.isBirthdays = isBirthdays
        self.isSubscribed = isSubscribed
        self.isGoogle = isGoogle
        self.allowsModifications = allowsModifications
    }

    /// Read by default: iCloud and on-device calendars and Birthdays; not Google
    /// (the relay has those) or Exchange.
    public var includedByDefault: Bool { !isGoogle && (isICloud || isBirthdays || source == "On My iPhone") }
}

/// EventKit, confined to an actor (`EKEventStore` isn't Sendable).
public actor EventKitCalendar: AppleCalendar {
    private let store = EKEventStore()

    public init() {}

    public nonisolated func access() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .full
        case .writeOnly: .writeOnly
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    public func requestAccess() async -> CalendarAccess {
        _ = try? await store.requestFullAccessToEvents()
        return access()
    }

    public func calendars() -> [AppleCalendarInfo] {
        guard access() == .full else { return [] }
        return store.calendars(for: .event).map { calendar in
            let source = calendar.source?.title ?? ""
            let sourceType = calendar.source?.sourceType
            return AppleCalendarInfo(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                source: source,
                isICloud: sourceType == .calDAV && source.lowercased().contains("icloud"),
                isBirthdays: calendar.type == .birthday,
                isSubscribed: calendar.type == .subscription,
                isGoogle: sourceType == .calDAV && (source.lowercased().contains("gmail") || source.lowercased().contains("google")),
                allowsModifications: calendar.allowsContentModifications
            )
        }
    }

    public func events(from: Date, to: Date, calendarIds: Set<String>?) -> [AgendaEvent] {
        guard access() == .full else { return [] }
        let infos = calendars()
        let wanted = infos.filter { calendarIds?.contains($0.id) ?? $0.includedByDefault }.map(\.id)
        let calendars = store.calendars(for: .event).filter { wanted.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        return store.events(matching: predicate).map(Self.agendaEvent)
    }

    static func agendaEvent(_ event: EKEvent) -> AgendaEvent {
        let start = event.startDate ?? Date()
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        let me = event.attendees?.first(where: \.isCurrentUser)
        let response: RSVP =
            switch me?.participantStatus {
            case .accepted: .accepted
            case .tentative: .tentative
            case .declined: .declined
            case .pending: .needsAction
            default: .none
            }
        let calendar = event.calendar
        return AgendaEvent(
            // Recurring occurrences share an identifier; the start keeps them apart.
            id: "a:\(identifier)@\(Int(start.timeIntervalSince1970))",
            source: .apple(calendarId: calendar?.calendarIdentifier ?? "", calendarName: calendar?.title ?? "Calendar"),
            sourceEventId: identifier,
            iCalUID: event.calendarItemExternalIdentifier,
            title: event.title ?? "(no title)",
            start: start,
            end: event.endDate ?? start,
            isAllDay: event.isAllDay,
            location: event.location,
            notes: event.notes,
            meetingLinks: [],
            myResponse: response,
            organizer: event.organizer?.name,
            attendeeCount: event.attendees?.count ?? 0,
            transparent: event.availability == .free,
            url: event.url?.absoluteString
        )
    }

    public nonisolated func changes() -> AsyncStream<Void> {
        // A plain async sequence of notifications: no framework callback lands on
        // an actor or the main actor (the Swift 6 executor-trap gotcha).
        AsyncStream { continuation in
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
