import Foundation
import HearthKit

/// What the StandBy widgets draw, written by the app to the App Group after every
/// refresh. Already safe for a shared nightstand: the partner's events are
/// busy-only, and surprise plans are reduced to "Private".
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Event: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var start: Date
        public var end: Date
        public var isAllDay: Bool
        /// A video call link exists (the widget shows a camera, never the link).
        public var hasCall: Bool
        /// The partner's event, shown "<name> is busy: …".
        public var isBusyOnly: Bool
        /// An invite still waiting on an answer.
        public var isInvite: Bool
        /// "work", "Family".
        public var calendar: String
    }

    public var generatedAt: Date
    public var fetchedAt: Date?
    public var ownerName: String
    public var timeZone: String
    /// The next 36 hours, soonest first.
    public var events: [Event]
    public var invitesWaiting: Int
    public var repliesReady: Int
    public var signals: Int
    /// The most pressing thing, for "Needs you".
    public var topNeed: String?
    /// The morning brief's headline.
    public var briefHeadline: String?

    public var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }

    public static let empty = WidgetSnapshot(
        generatedAt: .distantPast, ownerName: "", timeZone: TimeZone.current.identifier, events: [], invitesWaiting: 0,
        repliesReady: 0, signals: 0)

    public init(
        generatedAt: Date, fetchedAt: Date? = nil, ownerName: String, timeZone: String, events: [Event], invitesWaiting: Int,
        repliesReady: Int, signals: Int, topNeed: String? = nil, briefHeadline: String? = nil
    ) {
        self.generatedAt = generatedAt
        self.fetchedAt = fetchedAt
        self.ownerName = ownerName
        self.timeZone = timeZone
        self.events = events
        self.invitesWaiting = invitesWaiting
        self.repliesReady = repliesReady
        self.signals = signals
        self.topNeed = topNeed
        self.briefHeadline = briefHeadline
    }

    public static func make(
        agenda: Agenda, now: Date, fetchedAt: Date?, repliesReady: Int = 0, signals: Int = 0,
        briefHeadline: String? = nil
    ) -> WidgetSnapshot {
        let household = agenda.household
        let horizon = now.addingTimeInterval(36 * 3600)
        let events = agenda.events
            .filter { $0.end > now && $0.start < horizon && $0.myResponse != .declined }
            .prefix(40)
            .map { event in
                Event(
                    id: event.id,
                    title: SurpriseMarker.isSurprise(event) ? "Private" : BusyOnly.title(for: event, partnerName: household.partnerName),
                    start: event.start, end: event.end, isAllDay: event.isAllDay,
                    hasCall: !event.meetingLinks.isEmpty,
                    isBusyOnly: event.busyOnly,
                    isInvite: event.isWaitingOnMe,
                    calendar: event.source.label)
            }
        let waiting = agenda.waitingOnMe(now: now)
        return WidgetSnapshot(
            generatedAt: now,
            fetchedAt: fetchedAt,
            ownerName: household.ownerName,
            timeZone: household.timeZone,
            events: Array(events),
            invitesWaiting: waiting.count,
            repliesReady: repliesReady,
            signals: signals,
            topNeed: waiting.first.map { "RSVP: \($0.title)" },
            briefHeadline: briefHeadline
        )
    }

    /// The event the "Next up" widget shows at `date`: the first timed one that
    /// hasn't ended, the partner's left out.
    public func nextUp(at date: Date) -> Event? {
        events.filter { !$0.isAllDay && !$0.isBusyOnly && !$0.isInvite && $0.end > date }.min { $0.start < $1.start }
    }

    /// What's left of today at `date` (all-day first), for the "Today" widget.
    public func today(at date: Date) -> [Event] {
        let calendar = Fmt(zone: zone).calendar
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
        return events.filter { $0.end > date && $0.start < end }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    /// Moments the widgets should redraw: every start and end in the next 12 hours.
    public func boundaries(after date: Date, limit: Int = 30) -> [Date] {
        let horizon = date.addingTimeInterval(12 * 3600)
        let moments = events.flatMap { [$0.start, $0.end] }.filter { $0 > date && $0 < horizon }
        return Array(Set(moments)).sorted().prefix(limit).map { $0 }
    }
}

/// Where the app hands widget snapshots to WidgetKit.
public protocol WidgetPublishing: Sendable {
    func publish(_ snapshot: WidgetSnapshot)
}

public struct NoWidgets: WidgetPublishing {
    public init() {}
    public func publish(_ snapshot: WidgetSnapshot) {}
}

/// Reads and writes the snapshot file in the App Group container.
public struct WidgetSnapshotFile: Sendable {
    public static let fileName = "widget-snapshot.json"
    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    public func write(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try HearthJSON.encode(snapshot).write(to: url, options: options)
    }

    public func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? HearthJSON.decode(WidgetSnapshot.self, from: data)
    }
}
