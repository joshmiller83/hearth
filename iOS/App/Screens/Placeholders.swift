import SwiftUI

/// A screen whose milestone hasn't landed yet: what it will do, in the design's voice.
struct ComingSoon: View {
    var title: String
    var milestone: String
    var symbol: String
    var lines: [String]

    var body: some View {
        ScreenScroll {
            Text(title).font(.hTitle).displayTracking().foregroundStyle(Theme.ink)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            Card(padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        IconTile(symbol: symbol, tint: .ember, size: 42)
                        Text("Arrives with \(milestone)").eyebrow(Theme.emberSoft)
                    }
                    ForEach(lines, id: \.self) { line in
                        Text(line).font(.hBody).foregroundStyle(Theme.muted).lineSpacing(3)
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct InboxPlaceholder: View {
    var body: some View {
        ComingSoon(
            title: "Inbox", milestone: "M3", symbol: "tray",
            lines: [
                "Every inbox, swept every 15 minutes and sorted by your rules into Reply, Job hunt, Archive and Delete.",
                "Approve a queue per account with one tap, undo for 10 seconds, and nothing is ever deleted for good.",
            ])
    }
}

struct PeoplePlaceholder: View {
    var body: some View {
        ComingSoon(
            title: "People", milestone: "M7", symbol: "heart",
            lines: [
                "Your inner circle from Contacts, birthdays and anniversaries coming up, and small ways to show up.",
                "A quiet planner for surprises that stays off the shared calendars until you reveal it.",
            ])
    }
}

struct AskPlaceholder: View {
    var body: some View {
        ComingSoon(
            title: "Ask Hearth", milestone: "M5", symbol: "ellipsis.bubble",
            lines: [
                "Ask across your mail and calendars. Claude checks its sources, shows its work, and proposes actions you approve."
            ])
    }
}

struct SignalsPlaceholder: View {
    var body: some View {
        ComingSoon(
            title: "Signals", milestone: "M6", symbol: "bell",
            lines: [
                "GitHub reviews, weather alerts, serving schedules and shipping, with the noise quieted into bundles."
            ])
    }
}

struct AroundTownPlaceholder: View {
    var body: some View {
        Card(padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Arrives with M8").eyebrow(Theme.emberSoft)
                Text("Events around town from your feeds and pages, filtered to evenings you're both free.")
                    .font(.hBody).foregroundStyle(Theme.muted)
            }
        }
    }
}
