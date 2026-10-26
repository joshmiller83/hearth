import Foundation

/// Sorts what Claude read into the three lists the review screens show:
/// entries that need a look (Claude asked something), new ones, and ones
/// already on a calendar (matched and merged, never duplicated).
public struct CaptureTriage: Sendable, Equatable {
    public struct Match: Sendable, Equatable, Identifiable {
        public var entry: CaptureEntry
        public var event: AgendaEvent
        public var id: String { entry.id }
    }

    public var needsLook: [CaptureEntry]
    public var new: [CaptureEntry]
    public var alreadyOn: [Match]
}

public enum CaptureMatcher {
    public static func triage(_ entries: [CaptureEntry], agenda: Agenda) -> CaptureTriage {
        var triage = CaptureTriage(needsLook: [], new: [], alreadyOn: [])
        let zone = agenda.household.zone
        for entry in entries {
            if let event = agenda.events.first(where: { matches(entry, $0, zone: zone) }) {
                triage.alreadyOn.append(.init(entry: entry, event: event))
            } else if entry.question != nil {
                triage.needsLook.append(entry)
            } else {
                triage.new.append(entry)
            }
        }
        return triage
    }

    /// The same thing on the same day: a shared meaningful word, and at least half
    /// of the shorter title's words in common.
    public static func matches(_ entry: CaptureEntry, _ event: AgendaEvent, zone: TimeZone) -> Bool {
        guard let interval = entry.interval(in: zone) else { return false }
        let calendar = Fmt(zone: zone).calendar
        let sameDay =
            calendar.isDate(event.start, inSameDayAs: interval.start)
            || (event.isAllDay && event.start <= interval.start && event.end > interval.start)
        guard sameDay else { return false }
        let a = words(entry.title)
        let b = words(BusyOnly.title(for: event, partnerName: nil))
        guard !a.isEmpty, !b.isEmpty else { return false }
        let shared = a.intersection(b).count
        return shared >= 1 && Double(shared) / Double(min(a.count, b.count)) >= 0.5
    }

    static let ignored: Set<String> = [
        "the", "a", "an", "and", "or", "of", "for", "to", "at", "on", "in", "with", "is", "my", "our", "s", "day", "busy",
    ]

    /// Lowercased words, possessives folded ("Mom’s" → "mom"), filler dropped.
    static func words(_ title: String) -> Set<String> {
        let folded = title.lowercased().replacingOccurrences(of: "’", with: "'")
        let tokens = folded.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map { token -> String in
            var word = String(token)
            if word.hasSuffix("'s") { word.removeLast(2) }
            return word.replacingOccurrences(of: "'", with: "")
        }
        var set = Set(tokens.filter { !$0.isEmpty && !ignored.contains($0) })
        // "bday", "birthday" and "birthdays" are one word for matching.
        if !set.intersection(["bday", "birthday", "birthdays"]).isEmpty {
            set.subtract(["bday", "birthdays"])
            set.insert("birthday")
        }
        return set
    }
}
