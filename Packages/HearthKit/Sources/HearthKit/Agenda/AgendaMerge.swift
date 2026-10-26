import Foundation

/// Folds every calendar into one agenda with one row per real-world event.
///
/// The same invite often shows up several times: on two Google accounts, on a
/// shared Google calendar, and again in iCloud if the phone subscribes to it.
/// Copies are matched by iCalUID first (Google and CalDAV both carry it, and
/// recurring instances share it, so the start time is part of the key), then by
/// a fuzzy title-and-time match for copies that lost the UID on the way.
public enum AgendaMerge {
    /// How close two copies' times must be to count as the same event.
    public static let timeTolerance: TimeInterval = 5 * 60

    public static func merge(_ events: [AgendaEvent]) -> [AgendaEvent] {
        let ordered = events.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.start != b.start { return a.start < b.start }
            return a.id < b.id
        }
        var kept: [AgendaEvent] = []
        var byUID: [String: Int] = [:]
        var byTitle: [String: [Int]] = [:]

        for event in ordered {
            if let uid = event.iCalUID, let index = byUID[uidKey(uid, event)] {
                fold(event, into: &kept[index])
                continue
            }
            let title = normalizedTitle(event.title)
            if let candidates = byTitle[title], let index = candidates.first(where: { sameTime(kept[$0], event) }) {
                fold(event, into: &kept[index])
                if let uid = event.iCalUID { byUID[uidKey(uid, event)] = index }
                continue
            }
            kept.append(event)
            let index = kept.count - 1
            if let uid = event.iCalUID { byUID[uidKey(uid, event)] = index }
            if !title.isEmpty { byTitle[title, default: []].append(index) }
        }
        return kept.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            return a.title < b.title
        }
    }

    /// Which copy to keep, lowest first: the one waiting on an RSVP (so answering
    /// works from it), then the owner's Google copies, Apple, feeds, and last a
    /// partner's busy-only copy (when the owner has the event too, show theirs).
    static func rank(_ event: AgendaEvent) -> Int {
        if event.busyOnly { return 5 }
        if event.myResponse == .needsAction { return 0 }
        switch event.source {
        case .google: return event.myResponse == .none ? 2 : 1
        case .apple: return 3
        case .feed: return 4
        }
    }

    static func fold(_ copy: AgendaEvent, into kept: inout AgendaEvent) {
        if copy.source != kept.source, !kept.alsoOn.contains(copy.source) {
            kept.alsoOn.append(copy.source)
        }
        if kept.meetingLinks.isEmpty { kept.meetingLinks = copy.meetingLinks }
        if kept.location == nil { kept.location = copy.location }
        if kept.iCalUID == nil { kept.iCalUID = copy.iCalUID }
    }

    static func uidKey(_ uid: String, _ event: AgendaEvent) -> String {
        // Minutes since 1970 keep recurring instances apart.
        "\(uid)@\(Int(event.start.timeIntervalSince1970 / 60))"
    }

    static func sameTime(_ a: AgendaEvent, _ b: AgendaEvent) -> Bool {
        if a.isAllDay || b.isAllDay {
            return a.isAllDay == b.isAllDay && abs(a.start.timeIntervalSince(b.start)) < 12 * 3600
        }
        return abs(a.start.timeIntervalSince(b.start)) <= timeTolerance
            && abs(a.end.timeIntervalSince(b.end)) <= timeTolerance
    }

    /// Lowercased letters and digits only, so "Bible Study" and "bible study!" match.
    public static func normalizedTitle(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
