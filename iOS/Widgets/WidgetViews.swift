import HearthCore
import HearthKit
import SwiftUI
import WidgetKit

struct HearthEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// Colors that hold up in StandBy: full color by day; at night (and on the Lock
/// Screen and tinted Home Screens) the system renders in one tint, so meaning
/// rides on weight and size, never on color alone.
struct WidgetPalette {
    let mode: WidgetRenderingMode

    var full: Bool { mode == .fullColor }
    var ink: Color { full ? Theme.ink : .primary }
    var muted: Color { full ? Theme.muted : .secondary }
    var ice: Color { full ? Theme.ice : .primary }
    var ember: Color { full ? Theme.ember : .primary }
}

/// "Next up": the time, big; the title; whether there's a call.
struct NextUpView: View {
    let entry: HearthEntry
    /// Tests choose the family; WidgetKit's environment value can't be set.
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily
    @Environment(\.widgetRenderingMode) private var mode

    var family: WidgetFamily { familyOverride ?? environmentFamily }

    var body: some View {
        let palette = WidgetPalette(mode: mode)
        let fmt = Fmt(zone: entry.snapshot.zone)
        if let next = entry.snapshot.nextUp(at: entry.date) {
            let started = next.start <= entry.date
            let when = started ? "Now" : "Next up · " + fmt.relative(next.start, now: entry.date)
            switch family {
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(fmt.time(next.start)) · \(started ? "now" : fmt.relative(next.start, now: entry.date))")
                        .font(.system(size: 13, weight: .semibold))
                        .widgetAccentable()
                    Text(next.title).font(.system(size: 15, weight: .bold)).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                VStack(alignment: .leading, spacing: 0) {
                    Text(when.uppercased())
                        .font(.custom(Typeface.bold, size: 11, relativeTo: .caption2)).tracking(0.6)
                        .foregroundStyle(palette.ice)
                        .widgetAccentable()
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(fmt.timeNoMeridiem(next.start))
                            .font(.custom(Typeface.displayHeavy, size: 40, relativeTo: .largeTitle))
                            .minimumScaleFactor(0.7)
                        Text(fmt.meridiem(next.start)).font(.custom(Typeface.bold, size: 13, relativeTo: .caption))
                    }
                    .foregroundStyle(palette.ink)
                    .widgetAccentable()
                    Text(next.title)
                        .font(.custom(Typeface.semibold, size: 15, relativeTo: .body))
                        .foregroundStyle(palette.ink)
                        .lineLimit(2)
                        .padding(.top, 2)
                    HStack(spacing: 4) {
                        if next.hasCall { Image(systemName: "video.fill") }
                        Text(next.calendar).lineLimit(1)
                    }
                    .font(.custom(Typeface.medium, size: 12, relativeTo: .caption))
                    .foregroundStyle(palette.muted)
                    .padding(.top, 3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            NothingNext(snapshot: entry.snapshot, date: entry.date, palette: palette, compact: family == .accessoryRectangular)
        }
    }
}

struct NothingNext: View {
    let snapshot: WidgetSnapshot
    let date: Date
    let palette: WidgetPalette
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !compact {
                Image(systemName: "flame").font(.system(size: 22, weight: .semibold)).foregroundStyle(palette.ember).widgetAccentable()
                Spacer(minLength: 0)
            }
            Text(snapshot.generatedAt == .distantPast ? "Open Hearth once to fill this in." : "Nothing else today.")
                .font(.custom(Typeface.semibold, size: compact ? 14 : 16, relativeTo: .body))
                .foregroundStyle(palette.ink)
            if snapshot.invitesWaiting > 0 {
                Text("\(snapshot.invitesWaiting) invite\(snapshot.invitesWaiting == 1 ? "" : "s") waiting on you")
                    .font(.custom(Typeface.medium, size: 12, relativeTo: .caption))
                    .foregroundStyle(palette.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// "Today": the rest of the day, all-day first, partner events marked busy.
struct TodayListView: View {
    let entry: HearthEntry
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily
    @Environment(\.widgetRenderingMode) private var mode

    var family: WidgetFamily { familyOverride ?? environmentFamily }

    var body: some View {
        let palette = WidgetPalette(mode: mode)
        let fmt = Fmt(zone: entry.snapshot.zone)
        let events = entry.snapshot.today(at: entry.date)
        let limit = family == .systemMedium ? 5 : family == .accessoryRectangular ? 2 : 3
        if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(events.prefix(limit)) { event in
                    Text("\(event.isAllDay ? "All day" : fmt.time(event.start, compact: true)) \(event.title)")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                if events.isEmpty { Text("Nothing else today").font(.system(size: 13, weight: .semibold)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("TODAY").font(.custom(Typeface.bold, size: 11, relativeTo: .caption2)).tracking(0.6)
                        .foregroundStyle(palette.ember).widgetAccentable()
                    Spacer()
                    Text(fmt.weekdayTag(entry.date) + " \(fmt.dayOfMonth(entry.date))")
                        .font(.custom(Typeface.bold, size: 11, relativeTo: .caption2))
                        .foregroundStyle(palette.muted)
                }
                if events.isEmpty {
                    Spacer(minLength: 0)
                    Text("Nothing else today.").font(.custom(Typeface.semibold, size: 15, relativeTo: .body)).foregroundStyle(palette.ink)
                    Spacer(minLength: 0)
                } else {
                    ForEach(events.prefix(limit)) { event in
                        if family == .systemMedium {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(event.isAllDay ? "All day" : fmt.time(event.start, compact: true))
                                    .font(.custom(Typeface.bold, size: 12, relativeTo: .caption))
                                    .foregroundStyle(event.isBusyOnly ? palette.muted : palette.ink)
                                    .frame(width: 56, alignment: .leading)
                                Text(event.title)
                                    .font(.custom(event.isBusyOnly ? Typeface.medium : Typeface.semibold, size: 13, relativeTo: .footnote))
                                    .foregroundStyle(event.isBusyOnly ? palette.muted : palette.ink)
                                    .lineLimit(1)
                                if event.hasCall { Image(systemName: "video.fill").font(.system(size: 10)).foregroundStyle(palette.muted) }
                            }
                        } else {
                            // Small (and StandBy): the time above the title, so the title gets the width.
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 4) {
                                    Text(event.isAllDay ? "All day" : fmt.time(event.start, compact: true))
                                    if event.hasCall { Image(systemName: "video.fill").font(.system(size: 9)) }
                                }
                                .font(.custom(Typeface.bold, size: 11, relativeTo: .caption2))
                                .foregroundStyle(palette.muted)
                                Text(event.title)
                                    .font(.custom(event.isBusyOnly ? Typeface.medium : Typeface.semibold, size: 14, relativeTo: .footnote))
                                    .foregroundStyle(event.isBusyOnly ? palette.muted : palette.ink)
                                    .lineLimit(1)
                            }
                        }
                    }
                    if events.count > limit {
                        Text("+\(events.count - limit) more").font(.custom(Typeface.medium, size: 11, relativeTo: .caption2))
                            .foregroundStyle(palette.muted)
                    }
                    Spacer(minLength: 0)
                }
                if entry.snapshot.invitesWaiting > 0 {
                    Text("\(entry.snapshot.invitesWaiting) invite\(entry.snapshot.invitesWaiting == 1 ? "" : "s") waiting")
                        .font(.custom(Typeface.bold, size: 11, relativeTo: .caption2))
                        .foregroundStyle(palette.ember)
                        .widgetAccentable()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
