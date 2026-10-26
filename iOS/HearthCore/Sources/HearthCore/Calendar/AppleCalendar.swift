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

    /// Adds events to one calendar; returns their identifiers (for Undo).
    func add(_ drafts: [EventDraft], to calendarId: String) async throws -> [String]
    /// Removes events Hearth just added (Undo).
    func removeEvents(_ ids: [String]) async throws
    func remindersAccess() -> CalendarAccess
    func requestRemindersAccess() async -> CalendarAccess
    /// Adds reminders to the default list; returns their identifiers.
    func add(_ reminders: [ReminderDraft]) async throws -> [String]
    func removeReminders(_ ids: [String]) async throws
}

/// An event Hearth is about to add, already in instants.
public struct EventDraft: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var tentative: Bool
    /// When to alert (nil: no alarm).
    public var alarm: Date?
    public var repeats: CaptureEntry.Repeat?

    public init(
        title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil, notes: String? = nil,
        tentative: Bool = false, alarm: Date? = nil, repeats: CaptureEntry.Repeat? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.tentative = tentative
        self.alarm = alarm
        self.repeats = repeats
    }
}

/// A reminder Hearth is about to add.
public struct ReminderDraft: Sendable, Equatable {
    public var title: String
    public var due: Date
    public var notes: String?
    public var repeats: CaptureEntry.Repeat?

    public init(title: String, due: Date, notes: String? = nil, repeats: CaptureEntry.Repeat? = nil) {
        self.title = title
        self.due = due
        self.notes = notes
        self.repeats = repeats
    }
}

public enum CalendarWriteError: Error, Equatable, Sendable, CustomStringConvertible {
    case noAccess
    case noCalendar(String)
    case failed(String)

    public var description: String {
        switch self {
        case .noAccess: "Hearth needs calendar access for that. Allow it in Sources."
        case .noCalendar(let name): "There's no calendar called \(name) on this phone."
        case .failed(let detail): "The calendar didn't take it (\(detail))."
        }
    }
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

    // MARK: Writing

    public func add(_ drafts: [EventDraft], to calendarId: String) throws -> [String] {
        guard access() == .full else { throw CalendarWriteError.noAccess }
        guard let calendar = store.calendar(withIdentifier: calendarId) else { throw CalendarWriteError.noCalendar(calendarId) }
        var ids: [String] = []
        do {
            for draft in drafts {
                let event = EKEvent(eventStore: store)
                event.calendar = calendar
                event.title = draft.title
                event.startDate = draft.start
                event.endDate = draft.end
                event.isAllDay = draft.isAllDay
                event.location = draft.location
                event.notes = draft.notes
                event.availability = draft.tentative ? .tentative : .busy
                if let alarm = draft.alarm { event.addAlarm(EKAlarm(absoluteDate: alarm)) }
                if let repeats = draft.repeats { event.addRecurrenceRule(Self.rule(repeats)) }
                try store.save(event, span: .thisEvent, commit: false)
                if let id = event.eventIdentifier { ids.append(id) }
            }
            try store.commit()
        } catch {
            store.reset()
            throw CalendarWriteError.failed(error.localizedDescription)
        }
        return ids
    }

    public func removeEvents(_ ids: [String]) throws {
        for id in ids {
            if let event = store.event(withIdentifier: id) { try store.remove(event, span: .futureEvents, commit: false) }
        }
        try store.commit()
    }

    public nonisolated func remindersAccess() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .full
        case .writeOnly: .writeOnly
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    public func requestRemindersAccess() async -> CalendarAccess {
        _ = try? await store.requestFullAccessToReminders()
        return remindersAccess()
    }

    public func add(_ reminders: [ReminderDraft]) throws -> [String] {
        guard remindersAccess() == .full else { throw CalendarWriteError.noAccess }
        guard let list = store.defaultCalendarForNewReminders() else { throw CalendarWriteError.noCalendar("Reminders") }
        var ids: [String] = []
        do {
            for draft in reminders {
                let reminder = EKReminder(eventStore: store)
                reminder.calendar = list
                reminder.title = draft.title
                reminder.notes = draft.notes
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: draft.due)
                reminder.dueDateComponents = parts
                reminder.addAlarm(EKAlarm(absoluteDate: draft.due))
                if let repeats = draft.repeats { reminder.addRecurrenceRule(Self.rule(repeats)) }
                try store.save(reminder, commit: false)
                ids.append(reminder.calendarItemIdentifier)
            }
            try store.commit()
        } catch {
            store.reset()
            throw CalendarWriteError.failed(error.localizedDescription)
        }
        return ids
    }

    public func removeReminders(_ ids: [String]) throws {
        for id in ids {
            if let reminder = store.calendarItem(withIdentifier: id) as? EKReminder { try store.remove(reminder, commit: false) }
        }
        try store.commit()
    }

    static func rule(_ repeats: CaptureEntry.Repeat) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency =
            switch repeats.frequency {
            case .daily: .daily
            case .weekly: .weekly
            case .monthly: .monthly
            case .yearly: .yearly
            }
        let end = repeats.until.flatMap { RFC3339.date($0, zone: .current) }.map { EKRecurrenceEnd(end: $0) }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: max(1, repeats.interval), end: end)
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
