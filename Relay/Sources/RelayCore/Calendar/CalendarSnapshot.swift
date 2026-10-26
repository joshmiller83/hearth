import Foundation
import HearthKit

/// Turns gmailkit's calendar sweep into what the phone downloads: Hearth events
/// (partner events already busy-only), the calendar list, and any account that
/// couldn't be read.
public enum CalendarSnapshot {
    public static func build(
        rows: [GmailkitEventRow],
        calendars: [GmailkitCalendarRow],
        aliases: [String: String],
        household: Household,
        now: Date
    ) -> EventsResponse {
        func alias(_ email: String) -> String { aliases[email.lowercased()] ?? email }
        var problems: [SourceProblem] = []
        var events: [AgendaEvent] = []
        for row in rows {
            if let error = row.error {
                problems.append(SourceProblem(source: alias(row.account), message: error))
            } else if let event = row.agendaEvent(alias: alias, household: household) {
                events.append(event)
            }
        }
        var infos: [CalendarInfo] = []
        for row in calendars {
            if let error = row.error {
                if !problems.contains(where: { $0.source == alias(row.account) }) {
                    problems.append(SourceProblem(source: alias(row.account), message: error))
                }
                continue
            }
            guard let id = row.id, row.hidden != true else { continue }
            infos.append(
                CalendarInfo(
                    id: id, account: alias(row.account), name: row.summary ?? id,
                    isPrimary: row.primary ?? false, accessRole: row.access_role ?? ""))
        }
        return EventsResponse(events: events, calendars: infos, fetchedAt: now, problems: problems)
    }

    /// The cached events overlapping `[from, to)`.
    public static func window(_ snapshot: EventsResponse, from: Date, to: Date) -> EventsResponse {
        var out = snapshot
        out.events = snapshot.events.filter { $0.start < to && ($0.end > from || $0.start >= from) }
        return out
    }

    /// The cache after an RSVP went through: the event shows the new answer.
    public static func applying(rsvp response: RSVP, account: String, eventId: String, to snapshot: EventsResponse) -> EventsResponse {
        var out = snapshot
        for index in out.events.indices where out.events[index].sourceEventId == eventId && out.events[index].source.account == account {
            out.events[index].myResponse = response
        }
        return out
    }

    /// The cache with a new event (a hold Hearth just made).
    public static func adding(_ event: AgendaEvent, to snapshot: EventsResponse) -> EventsResponse {
        var out = snapshot
        out.events.removeAll { $0.id == event.id }
        out.events.append(event)
        out.events.sort { $0.start < $1.start }
        return out
    }

    /// The cache without an event (a hold Hearth just removed).
    public static func removing(account: String, eventId: String, from snapshot: EventsResponse) -> EventsResponse {
        var out = snapshot
        out.events.removeAll { $0.sourceEventId == eventId && $0.source.account == account }
        return out
    }
}
