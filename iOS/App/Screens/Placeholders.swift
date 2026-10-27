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
