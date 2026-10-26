import Foundation

/// A merged agenda and the questions the Plans and Today screens ask of it.
public struct Agenda: Sendable {
    public var events: [AgendaEvent]
    public var household: Household

    public init(events: [AgendaEvent], household: Household) {
        self.events = AgendaMerge.merge(events)
        self.household = household
    }

    var calendar: Calendar { RFC3339.calendar(household.zone) }

    /// Events touching `day` (any time that day), declined ones left out,
    /// all-day events first.
    public func events(on day: Date) -> [AgendaEvent] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return
            events
            .filter { $0.myResponse != .declined && $0.start < end && ($0.end > start || $0.start >= start) }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.start < b.start
            }
    }

    /// The owner's next timed commitment that hasn't started yet (or started in
    /// the last five minutes, so a call you're late for stays up top). Unanswered
    /// invites aren't commitments yet.
    public func nextUp(now: Date) -> AgendaEvent? {
        events
            .filter { $0.blocksTime && !$0.busyOnly && $0.start >= now.addingTimeInterval(-5 * 60) && $0.end > now }
            .min { $0.start < $1.start }
    }

    /// Invites still waiting on the owner, soonest first. Past ones drop off.
    public func waitingOnMe(now: Date) -> [AgendaEvent] {
        events.filter { $0.isWaitingOnMe && $0.end > now }.sorted { $0.start < $1.start }
    }

    /// The owner's own events (not the partner's) that take up time during `event`.
    public func conflicts(with event: AgendaEvent) -> [AgendaEvent] {
        events.filter { other in
            other.id != event.id && !other.busyOnly && other.blocksTime && other.overlaps(event)
                && !(other.iCalUID != nil && other.iCalUID == event.iCalUID)
        }
    }

    /// "Overlaps Bible study, 7:00–8:30 PM on team".
    public func conflictSentence(for event: AgendaEvent) -> String? {
        guard let other = conflicts(with: event).first else { return nil }
        let fmt = household.fmt
        return "Overlaps \(other.title), \(fmt.timeRange(other.start, other.end)) on \(other.source.label)"
    }

    /// The seven days starting with `today`, with what the design's week strip
    /// shows under each: an ember dot for a day with an invite waiting, a muted
    /// one for a day with plans.
    public func week(from today: Date) -> [WeekDay] {
        let first = calendar.startOfDay(for: today)
        let fmt = household.fmt
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
            let onDay = events(on: day).filter { !$0.busyOnly }
            let mark: WeekDay.Mark = onDay.contains(where: \.isWaitingOnMe) ? .invite : (onDay.isEmpty ? .none : .plans)
            return WeekDay(date: day, tag: fmt.weekdayTag(day), number: fmt.dayOfMonth(day), isToday: offset == 0, mark: mark)
        }
    }

    /// Evenings (from `from` to `to` local time) on the next `days` days when
    /// nothing of the owner's or the partner's blocks that window.
    public func freeEvenings(now: Date, days: Int = 14, fromHour: Int = 18, toHour: Int = 22) -> [DateInterval] {
        let first = calendar.startOfDay(for: now)
        return (0..<days).compactMap { offset -> DateInterval? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: first),
                let start = calendar.date(bySettingHour: fromHour, minute: 0, second: 0, of: day),
                let end = calendar.date(bySettingHour: toHour, minute: 0, second: 0, of: day),
                end > now
            else { return nil }
            let window = DateInterval(start: max(start, now), end: end)
            let busy = events.contains { e in
                (e.blocksTime || (e.busyOnly && !e.transparent && !e.isAllDay)) && e.start < window.end && e.end > window.start
            }
            return busy ? nil : window
        }
    }
}

public struct WeekDay: Sendable, Hashable, Identifiable {
    public enum Mark: Sendable, Hashable { case none, plans, invite }
    public var date: Date
    public var tag: String
    public var number: Int
    public var isToday: Bool
    public var mark: Mark
    public var id: Date { date }
}
