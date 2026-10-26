import Foundation

/// The few ways Hearth writes dates and times, in the design's voice:
/// "7:00 PM", "7:00–8:30 PM", "Thu, Oct 29", "in 52 min".
///
/// Built from calendar components rather than `DateFormatter` so the output is
/// the same on every platform (the relay's tests run on Linux) and in any locale.
public struct Fmt: Sendable {
    public var zone: TimeZone

    public init(zone: TimeZone) {
        self.zone = zone
    }

    public static let weekdaysShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    public static let weekdaysLong = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    public static let monthsShort = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    public static let monthsLong = [
        "January", "February", "March", "April", "May", "June", "July", "August",
        "September", "October", "November", "December",
    ]

    public var calendar: Calendar { RFC3339.calendar(zone) }

    private func parts(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
    }

    /// "7:00 PM" (or "7 PM" with `compact` on the hour).
    public func time(_ date: Date, compact: Bool = false) -> String {
        let p = parts(date)
        return clock(hour: p.hour ?? 0, minute: p.minute ?? 0, compact: compact) + " " + meridiem(p.hour ?? 0)
    }

    /// "7:00" without AM/PM, for the second half of a range or a time column.
    public func timeNoMeridiem(_ date: Date) -> String {
        let p = parts(date)
        return clock(hour: p.hour ?? 0, minute: p.minute ?? 0, compact: false)
    }

    /// "AM" or "PM".
    public func meridiem(_ date: Date) -> String { meridiem(parts(date).hour ?? 0) }

    /// "7:00–8:30 PM", or "11:30 AM–1:00 PM" when the range crosses noon.
    public func timeRange(_ start: Date, _ end: Date, compact: Bool = false) -> String {
        let a = parts(start)
        let b = parts(end)
        let sameHalf = ((a.hour ?? 0) < 12) == ((b.hour ?? 0) < 12) && calendar.isDate(start, inSameDayAs: end)
        let left = clock(hour: a.hour ?? 0, minute: a.minute ?? 0, compact: compact)
        let right = clock(hour: b.hour ?? 0, minute: b.minute ?? 0, compact: compact) + " " + meridiem(b.hour ?? 0)
        return sameHalf ? left + "–" + right : left + " " + meridiem(a.hour ?? 0) + "–" + right
    }

    /// "Thu, Oct 29".
    public func shortDay(_ date: Date) -> String {
        let p = parts(date)
        return Fmt.weekdaysShort[(p.weekday ?? 1) - 1] + ", " + Fmt.monthsShort[(p.month ?? 1) - 1] + " " + String(p.day ?? 1)
    }

    /// "Monday, October 26".
    public func longDay(_ date: Date) -> String {
        let p = parts(date)
        return Fmt.weekdaysLong[(p.weekday ?? 1) - 1] + ", " + Fmt.monthsLong[(p.month ?? 1) - 1] + " " + String(p.day ?? 1)
    }

    /// "THU".
    public func weekdayTag(_ date: Date) -> String {
        Fmt.weekdaysShort[(parts(date).weekday ?? 1) - 1].uppercased()
    }

    /// "Thu".
    public func weekday(_ date: Date) -> String {
        Fmt.weekdaysShort[(parts(date).weekday ?? 1) - 1]
    }

    public func dayOfMonth(_ date: Date) -> Int { parts(date).day ?? 1 }

    /// "Thu, Oct 29 · 7:00–8:00 PM", or "Thu, Oct 29 · all day".
    public func when(_ start: Date, _ end: Date, allDay: Bool) -> String {
        allDay ? shortDay(start) + " · all day" : shortDay(start) + " · " + timeRange(start, end)
    }

    /// "in 52 min", "in 2 h", "now", "5 min ago", "2 h ago", "yesterday", "3 days ago".
    public func relative(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        let minutes = Int((abs(seconds) / 60).rounded())
        if minutes < 1 { return "now" }
        let future = seconds > 0
        if minutes < 60 { return future ? "in \(minutes) min" : "\(minutes) min ago" }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 24 { return future ? "in \(hours) h" : "\(hours) h ago" }
        let days = abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0)
        if days == 1 { return future ? "tomorrow" : "yesterday" }
        return future ? "in \(days) days" : "\(days) days ago"
    }

    /// The minutes until `date`, for "Next up · in 52 min".
    public func minutesUntil(_ date: Date, now: Date) -> Int {
        Int((date.timeIntervalSince(now) / 60).rounded(.up))
    }

    private func clock(hour: Int, minute: Int, compact: Bool) -> String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        if compact && minute == 0 { return String(h12) }
        return String(h12) + ":" + (minute < 10 ? "0" : "") + String(minute)
    }

    private func meridiem(_ hour: Int) -> String { hour < 12 ? "AM" : "PM" }
}
