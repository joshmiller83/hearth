import HearthCore
import HearthKit
import SwiftUI

/// Plans · Around town: what the feeds hold, matched to evenings and weekends
/// that are open for you both.
struct AroundTownSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let town = app.town
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text(intro).font(.custom(Typeface.regular, size: 14, relativeTo: .subheadline)).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                NavigationLink {
                    FeedsView()
                } label: {
                    Image(systemName: "dot.radiowaves.up.forward").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                        .frame(width: Theme.touch, height: Theme.touch).background(Theme.chip, in: Circle())
                }
                .accessibilityLabel("Event feeds: add one with Claude")
            }
            .padding(.leading, 4)
            if let problem = town.problem { Notice(text: problem) }
            if let featured = town.featured { FeaturedEvent(event: featured) }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(town.chips, id: \.label) { chip in
                        let on = town.filter == chip.filter
                        Button(chip.label) { town.filter = chip.filter }
                            .font(.custom(Typeface.semibold, size: 14, relativeTo: .subheadline))
                            .foregroundStyle(on ? Theme.bg : Theme.chipInk)
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                            .background(on ? Theme.ink : Theme.chip, in: Capsule())
                            .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            let events = town.shown.filter { $0.id != town.featured?.id || town.filter != .forYouTwo }
            VStack(spacing: 0) {
                if events.isEmpty {
                    Text(
                        town.feeds.isEmpty
                            ? "No feeds yet. Tap the feeds button to add one with Claude." : "Nothing here in the next two months."
                    )
                    .font(.hBody).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
                }
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    TownRow(event: event).overlay(alignment: .top) { if index > 0 { Hairline() } }
                }
            }
            .padding(.horizontal, 14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Upcoming events")
        }
    }

    /// "From the church office email, the borough's page and the library, matched to evenings you and Robin both have open."
    var intro: String {
        let names = app.town.feeds.prefix(4).map { $0.name.prefix(1).lowercased() + $0.name.dropFirst() }
        let partner = app.household.partnerName.map { "you and \($0) both" } ?? "you"
        guard !names.isEmpty else { return "Events from feeds you follow, matched to evenings \(partner) have open." }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "From the \(list), matched to evenings \(partner) have open."
    }
}

/// The weekend's pick.
private struct FeaturedEvent: View {
    @Environment(AppModel.self) private var app
    let event: FeedEvent

    var body: some View {
        let town = app.town
        let fmt = app.household.fmt
        let added = town.isAdded(event)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DateTile(date: event.start, fmt: fmt, big: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("This weekend · \(town.feed(event)?.category ?? "around town")").eyebrow(Theme.emberSoft)
                    Text(event.title).font(.custom(Typeface.display, size: 22, relativeTo: .title2)).foregroundStyle(Theme.ink)
                    Text(town.place(event)).font(.hMeta).foregroundStyle(Theme.muted)
                }
            }
            Text(event.summary ?? town.why(event)).font(.custom(Typeface.regular, size: 14, relativeTo: .subheadline)).foregroundStyle(
                Theme.inkSoft)
            HStack(spacing: 8) {
                Button(added ? "On your calendar" : "Add to calendar") { Task { await town.toggle(event) } }
                    .buttonStyle(.pill(added ? .ice : .primary, height: 44))
                    .accessibilityAddTraits(added ? .isSelected : [])
                ShareLink(item: town.shareText(event)) {
                    Text("Send to \(app.household.partnerName ?? "someone")")
                }
                .buttonStyle(.pill(.secondary, height: 44))
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.emberLine, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Featured: \(event.title)")
    }
}

/// "SAT / 31 / OCT".
struct DateTile: View {
    let date: Date
    let fmt: Fmt
    var big = false

    var body: some View {
        VStack(spacing: 0) {
            Text(fmt.weekdayTag(date)).font(.custom(Typeface.bold, size: 10, relativeTo: .caption2)).foregroundStyle(Theme.emberSoft)
            Text("\(fmt.dayOfMonth(date))").font(.custom(Typeface.display, size: big ? 24 : 20, relativeTo: .title3)).foregroundStyle(
                Theme.ink)
            if !big {
                Text(Fmt.monthsShort[fmt.calendar.component(.month, from: date) - 1].uppercased())
                    .font(.custom(Typeface.bold, size: 9, relativeTo: .caption2)).foregroundStyle(Theme.muted)
            }
        }
        .frame(width: big ? 56 : 48, height: big ? 56 : 54)
        .background(big ? Theme.emberDeep : Theme.chip, in: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// One event: when, what, where, why it fits, and add.
private struct TownRow: View {
    @Environment(AppModel.self) private var app
    let event: FeedEvent

    var body: some View {
        let town = app.town
        let added = town.isAdded(event)
        HStack(spacing: 12) {
            DateTile(date: event.start, fmt: app.household.fmt)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.custom(Typeface.semibold, size: 15, relativeTo: .body)).foregroundStyle(Theme.ink)
                Text(town.place(event)).font(.hMeta).foregroundStyle(Theme.inkSoft)
                Text(town.why(event)).font(.custom(Typeface.regular, size: 12, relativeTo: .caption)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await town.toggle(event) }
            } label: {
                Image(systemName: added ? "checkmark" : "plus").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(added ? Theme.onEmber : Theme.ink)
                    .frame(width: 40, height: 40)
                    .background(added ? Theme.ember : Color.clear, in: Circle())
                    .overlay(Circle().strokeBorder(added ? Theme.ember : Theme.stoneDeep, lineWidth: 1.5))
                    .frame(width: Theme.touch, height: Theme.touch)
            }
            .accessibilityLabel(added ? "Remove \(event.title) from calendar" : "Add \(event.title) to calendar")
        }
        .padding(.vertical, 12)
    }
}
