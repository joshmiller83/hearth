import Foundation

/// Reads and writes the date-time text the relay, gmailkit and Claude exchange.
///
/// Written by hand rather than with `ISO8601DateFormatter` because the inputs
/// vary (gmailkit drops seconds, all-day events are bare dates, Claude may omit
/// the offset) and because formatters aren't `Sendable`.
public enum RFC3339 {
    public struct Parsed: Equatable, Sendable {
        public var date: Date
        /// True for a bare `YYYY-MM-DD`: midnight in the given zone.
        public var isDateOnly: Bool
        /// True when the text carried `Z` or an offset; false when it was read in the given zone.
        public var hadOffset: Bool
    }

    /// Parses `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM`, `…:SS`, `…:SS.fff`, each optionally
    /// followed by `Z`, `±HH:MM` or `±HHMM`. Text without an offset is wall-clock
    /// time in `zone`.
    public static func parse(_ text: String, zone: TimeZone = .gmt) -> Parsed? {
        let s = Array(text.trimmingCharacters(in: .whitespaces).utf8)
        var i = 0
        func number(_ count: Int) -> Int? {
            guard i + count <= s.count else { return nil }
            var value = 0
            for k in 0..<count {
                let b = s[i + k]
                guard b >= 48 && b <= 57 else { return nil }
                value = value * 10 + Int(b - 48)
            }
            i += count
            return value
        }
        func take(_ ascii: Character) -> Bool {
            guard i < s.count, s[i] == ascii.asciiValue! else { return false }
            i += 1
            return true
        }

        guard let year = number(4), take("-"), let month = number(2), take("-"), let day = number(2) else { return nil }
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents(year: year, month: month, day: day, hour: 0, minute: 0, second: 0)

        if i == s.count {
            return dateFrom(components, zone: zone).map { Parsed(date: $0, isDateOnly: true, hadOffset: false) }
        }
        guard take("T") || take(" "), let hour = number(2), take(":"), let minute = number(2) else { return nil }
        guard hour < 24, minute < 60 else { return nil }
        components.hour = hour
        components.minute = minute
        var fraction = 0.0
        if take(":") {
            guard let second = number(2), second < 61 else { return nil }
            components.second = min(second, 59)
            if take(".") || take(",") {
                var scale = 0.1
                while i < s.count, s[i] >= 48 && s[i] <= 57 {
                    fraction += Double(s[i] - 48) * scale
                    scale /= 10
                    i += 1
                }
            }
        }

        var offset: Int?
        if take("Z") || take("z") {
            offset = 0
        } else if i < s.count, s[i] == UInt8(ascii: "+") || s[i] == UInt8(ascii: "-") {
            let sign = s[i] == UInt8(ascii: "-") ? -1 : 1
            i += 1
            guard let oh = number(2) else { return nil }
            _ = take(":")
            let om = number(2) ?? 0
            offset = sign * (oh * 3600 + om * 60)
        }
        guard i == s.count else { return nil }

        let resolvedZone = offset.flatMap { TimeZone(secondsFromGMT: $0) } ?? zone
        guard let date = dateFrom(components, zone: resolvedZone) else { return nil }
        return Parsed(date: date.addingTimeInterval(fraction), isDateOnly: false, hadOffset: offset != nil)
    }

    /// `parse` for callers that only want the instant.
    public static func date(_ text: String, zone: TimeZone = .gmt) -> Date? {
        parse(text, zone: zone)?.date
    }

    /// `2026-10-29T23:00:00Z`: UTC, whole seconds.
    public static func format(_ date: Date) -> String {
        format(date, zone: .gmt)
    }

    /// `2026-10-29T19:00:00-04:00`: wall-clock time in `zone` with its offset.
    public static func format(_ date: Date, zone: TimeZone) -> String {
        let c = calendar(zone).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = zone.secondsFromGMT(for: date)
        var out = pad(c.year ?? 0, 4) + "-" + pad(c.month ?? 0, 2) + "-" + pad(c.day ?? 0, 2)
        out += "T" + pad(c.hour ?? 0, 2) + ":" + pad(c.minute ?? 0, 2) + ":" + pad(c.second ?? 0, 2)
        if offset == 0 { return out + "Z" }
        let sign = offset < 0 ? "-" : "+"
        let minutes = abs(offset) / 60
        return out + sign + pad(minutes / 60, 2) + ":" + pad(minutes % 60, 2)
    }

    /// `2026-10-29`: the calendar day `date` falls on in `zone`.
    public static func day(_ date: Date, zone: TimeZone) -> String {
        let c = calendar(zone).dateComponents([.year, .month, .day], from: date)
        return pad(c.year ?? 0, 4) + "-" + pad(c.month ?? 0, 2) + "-" + pad(c.day ?? 0, 2)
    }

    static func dateFrom(_ components: DateComponents, zone: TimeZone) -> Date? {
        var c = components
        c.timeZone = zone
        return calendar(zone).date(from: c)
    }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }
}
