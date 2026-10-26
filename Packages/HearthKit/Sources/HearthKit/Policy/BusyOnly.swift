import Foundation

/// The partner's events, as the owner sees them: the title and the time, marked
/// busy, with everything else (place, notes, links, guests) dropped. The relay
/// applies it before an event leaves the iMac, so the details never reach the phone.
public enum BusyOnly {
    public static func redact(_ event: AgendaEvent) -> AgendaEvent {
        var e = event
        e.busyOnly = true
        e.location = nil
        e.notes = nil
        e.meetingLinks = []
        e.attendeeCount = 0
        e.organizer = nil
        e.url = nil
        // Their RSVP state is theirs; it must never put an invite in the owner's queue.
        e.myResponse = .none
        return e
    }

    /// "Robin is busy: book club".
    public static func title(for event: AgendaEvent, partnerName: String?) -> String {
        guard event.busyOnly else { return event.title }
        return "\(partnerName ?? "Busy") is busy: \(event.title)"
    }
}
