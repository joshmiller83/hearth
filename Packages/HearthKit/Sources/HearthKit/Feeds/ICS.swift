import Foundation

/// Reads iCalendar feeds (RFC 5545) well enough for event calendars: the
/// VEVENTs, their times in UTC, a TZID or floating, all-day dates, durations,
/// and the common repeats (daily, weekly by weekday, monthly by day).
public enum ICS {
    /// The calendar's own name (`X-WR-CALNAME`), when it has one.
    public static func calendarName(_ text: String) -> String? {
        unfold(text).first { $0.uppercased().hasPrefix("X-WR-CALNAME") }.flatMap { property($0)?.value }.map(unescape)
    }

    /// Every occurrence in `from..<to`, cancelled ones left out.
    public static func events(_ text: String, feedId: String, zone: TimeZone, from: Date, to: Date) -> [FeedEvent] {
        var out: [FeedEvent] = []
        var current: [(name: String, params: [String: String], value: String)]?
        for line in unfold(text) {
            let upper = line.uppercased()
            if upper == "BEGIN:VEVENT" {
                current = []
            } else if upper == "END:VEVENT" {
                if let props = current { out += occurrences(props, feedId: feedId, zone: zone, from: from, to: to) }
                current = nil
            } else if current != nil, let prop = property(line) {
                current?.append(prop)
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    // MARK: Lines and properties

    /// Long lines continue on the next one after a space or tab.
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false)
        {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else {
                lines.append(String(raw))
            }
        }
        return lines.filter { !$0.isEmpty }
    }

    /// "DTSTART;TZID=America/New_York:20261107T100000" → name, params, value.
    static func property(_ line: String) -> (name: String, params: [String: String], value: String)? {
        // The value starts at the first colon outside a quoted parameter.
        var inQuotes = false
        var split: String.Index?
        for index in line.indices {
            let c = line[index]
            if c == "\"" { inQuotes.toggle() }
            if c == ":", !inQuotes {
                split = index
                break
            }
        }
        guard let split else { return nil }
        let head = line[..<split].split(separator: ";").map(String.init)
        guard let name = head.first?.uppercased() else { return nil }
        var params: [String: String] = [:]
        for param in head.dropFirst() {
            let pair = param.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { params[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return (name, params, String(line[line.index(after: split)...]))
    }

    static func unescape(_ text: String) -> String {
        var out = ""
        var escaping = false
        for c in text {
            if escaping {
                out.append(c == "n" || c == "N" ? "\n" : c)
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    // MARK: Times

    /// A DTSTART/DTEND value: UTC ("Z"), in its TZID, floating (home's zone), or a date.
    static func date(_ value: String, params: [String: String], zone: TimeZone) -> (date: Date, allDay: Bool)? {
        let digits = value.filter { $0.isNumber || $0 == "T" || $0 == "Z" }
        let allDay = params["VALUE"]?.uppercased() == "DATE" || !digits.contains("T")
        let zoneHere: TimeZone =
            digits.hasSuffix("Z") ? TimeZone(identifier: "UTC")! : params["TZID"].flatMap { TimeZone(identifier: $0) } ?? zone
        let plain = digits.replacingOccurrences(of: "Z", with: "").replacingOccurrences(of: "T", with: "")
        func part(_ from: Int, _ length: Int) -> Int? {
            guard plain.count >= from + length else { return nil }
            let start = plain.index(plain.startIndex, offsetBy: from)
            return Int(plain[start..<plain.index(start, offsetBy: length)])
        }
        guard let year = part(0, 4), let month = part(4, 2), let day = part(6, 2) else { return nil }
        var components = DateComponents(year: year, month: month, day: day)
        if !allDay {
            components.hour = part(8, 2) ?? 0
            components.minute = part(10, 2) ?? 0
            components.second = part(12, 2) ?? 0
        }
        return RFC3339.dateFrom(components, zone: allDay ? zone : zoneHere).map { ($0, allDay) }
    }

    /// "PT1H30M", "P1D", "P1DT2H" in seconds.
    static func duration(_ text: String) -> TimeInterval? {
        var seconds: TimeInterval = 0
        var number = ""
        var inTime = false
        for c in text.uppercased() {
            switch c {
            case "P", "+": continue
            case "T": inTime = true
            case "0"..."9": number.append(c)
            case "W":
                seconds += (Double(number) ?? 0) * 7 * 86400
                number = ""
            case "D":
                seconds += (Double(number) ?? 0) * 86400
                number = ""
            case "H":
                seconds += (Double(number) ?? 0) * 3600
                number = ""
            case "M":
                seconds += (Double(number) ?? 0) * (inTime ? 60 : 30 * 86400)
                number = ""
            case "S":
                seconds += Double(number) ?? 0
                number = ""
            default: return nil
            }
        }
        return seconds > 0 ? seconds : nil
    }

    // MARK: Events

    static func occurrences(
        _ props: [(name: String, params: [String: String], value: String)], feedId: String, zone: TimeZone, from: Date, to: Date
    ) -> [FeedEvent] {
        func first(_ name: String) -> (params: [String: String], value: String)? {
            props.first { $0.name == name }.map { ($0.params, $0.value) }
        }
        if first("STATUS")?.value.uppercased() == "CANCELLED" { return [] }
        guard let startProp = first("DTSTART"), let start = date(startProp.value, params: startProp.params, zone: zone) else { return [] }
        var length: TimeInterval = start.allDay ? 86400 : 3600
        if let endProp = first("DTEND"), let end = date(endProp.value, params: endProp.params, zone: zone), end.date > start.date {
            length = end.date.timeIntervalSince(start.date)
        } else if let span = first("DURATION").flatMap({ duration($0.value) }) {
            length = span
        }
        let title = first("SUMMARY").map { unescape($0.value) }?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !title.isEmpty else { return [] }
        let uid = first("UID")?.value ?? "\(title)-\(start.date.timeIntervalSince1970)"
        let description = first("DESCRIPTION").map { unescape($0.value) }
        let location = first("LOCATION").map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 }
        let link = first("URL").flatMap { URL(string: $0.value) }
        let text = (title + " " + (description ?? "")).lowercased()
        let free = text.contains("free") && !text.contains("free will offering") || text.contains("no cost") || text.contains("no charge")
        let summary = description?.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }

        let starts = repeats(start.date, rule: first("RRULE")?.value, allDay: start.allDay, zone: zone, until: to)
        return starts.filter { $0.addingTimeInterval(length) > from && $0 < to }.map { occurrence in
            FeedEvent(
                id: "\(feedId):\(uid):\(Int(occurrence.timeIntervalSince1970))", feedId: feedId, uid: uid, title: title, start: occurrence,
                end: occurrence.addingTimeInterval(length), isAllDay: start.allDay, location: location, url: link,
                summary: summary?.isEmpty == false ? summary : nil, free: free)
        }
    }

    /// The starts of a repeating event up to `until`: DAILY, WEEKLY (with BYDAY)
    /// and MONTHLY (on the same day); anything else counts once.
    static func repeats(_ start: Date, rule: String?, allDay: Bool, zone: TimeZone, until: Date) -> [Date] {
        guard let rule else { return [start] }
        var parts: [String: String] = [:]
        for piece in rule.split(separator: ";") {
            let pair = piece.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { parts[pair[0].uppercased()] = pair[1].uppercased() }
        }
        let calendar = RFC3339.calendar(zone)
        let interval = max(Int(parts["INTERVAL"] ?? "1") ?? 1, 1)
        let count = parts["COUNT"].flatMap { Int($0) } ?? 500
        let end = min(parts["UNTIL"].flatMap { date($0, params: [:], zone: zone)?.date } ?? until, until)
        let weekdays = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        let byDay = (parts["BYDAY"]?.split(separator: ",").compactMap { day in weekdays.firstIndex(of: String(day.suffix(2))) }).map {
            Set($0.map { $0 + 1 })
        }
        var out: [Date] = []
        switch parts["FREQ"] {
        case "DAILY":
            var day = start
            while day <= end, out.count < count {
                out.append(day)
                guard let next = calendar.date(byAdding: .day, value: interval, to: day) else { break }
                day = next
            }
        case "WEEKLY":
            let days = byDay ?? [calendar.component(.weekday, from: start)]
            var weekStart = calendar.date(byAdding: .day, value: 1 - calendar.component(.weekday, from: start), to: start) ?? start
            while weekStart <= end, out.count < count {
                for weekday in days.sorted() {
                    guard let day = calendar.date(byAdding: .day, value: weekday - 1, to: weekStart) else { continue }
                    if day >= start, day <= end, out.count < count { out.append(day) }
                }
                guard let next = calendar.date(byAdding: .day, value: 7 * interval, to: weekStart) else { break }
                weekStart = next
            }
        case "MONTHLY" where parts["BYDAY"] == nil:
            var index = 0
            while out.count < count, let day = calendar.date(byAdding: .month, value: index * interval, to: start), day <= end {
                out.append(day)
                index += 1
            }
        default:
            out = [start]
        }
        return out
    }
}
