import HearthCore
import HearthKit
import HearthKitTestSupport
import SwiftUI
import WidgetKit

@main
struct HearthWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextUpWidget()
        TodayWidget()
    }
}

/// Where the widgets get their data: the snapshot the app wrote to the App
/// Group, refreshed from the relay when it's stale.
enum WidgetStore {
    static var appGroup: String? { Bundle.main.object(forInfoDictionaryKey: "HearthAppGroup") as? String }

    static var keychainGroup: String? {
        (Bundle.main.object(forInfoDictionaryKey: "HearthKeychainGroup") as? String).flatMap { $0.hasPrefix("$(") ? nil : $0 }
    }

    static var file: WidgetSnapshotFile {
        WidgetSnapshotFile(directory: AppDatabase.directory(appGroup: appGroup))
    }

    static func current() -> WidgetSnapshot {
        file.read() ?? .empty
    }

    static func refreshed(now: Date) async -> WidgetSnapshot {
        let saved = current()
        guard now.timeIntervalSince(saved.generatedAt) > WidgetRefresh.staleAfter,
            let services = try? AppServices.live(appGroup: appGroup, keychainGroup: keychainGroup),
            let fresh = await WidgetRefresh.run(services: services, now: now)
        else { return saved }
        var merged = fresh
        // Counts the widget can't work out alone (replies, signals, the brief) stay from the app's snapshot.
        merged.repliesReady = saved.repliesReady
        merged.signals = saved.signals
        merged.briefHeadline = saved.briefHeadline
        try? file.write(merged)
        return merged
    }

    /// The design's Monday, for the widget gallery.
    static var preview: WidgetSnapshot {
        WidgetSnapshot.make(
            agenda: Agenda(events: Fixtures.week, household: Fixtures.household), now: Fixtures.now,
            fetchedAt: Fixtures.now)
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> HearthEntry {
        HearthEntry(date: Fixtures.now, snapshot: WidgetStore.preview)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (HearthEntry) -> Void) {
        if context.isPreview {
            completion(HearthEntry(date: Fixtures.now, snapshot: WidgetStore.preview))
        } else {
            completion(HearthEntry(date: Date(), snapshot: WidgetStore.current()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<HearthEntry>) -> Void) {
        Task {
            let now = Date()
            let snapshot = await WidgetStore.refreshed(now: now)
            // Redraw at every start and end so "Next up" moves on by itself.
            let entries = ([now] + snapshot.boundaries(after: now)).map { HearthEntry(date: $0, snapshot: snapshot) }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
        }
    }
}

struct NextUpWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextUp", provider: Provider()) { entry in
            NextUpView(entry: entry)
                .containerBackground(for: .widget) { Theme.surface }
                .widgetURL(URL(string: "hearth://plans"))
        }
        .configurationDisplayName("Next up")
        .description("Your next commitment from every calendar, made for StandBy.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Today", provider: Provider()) { entry in
            TodayListView(entry: entry)
                .containerBackground(for: .widget) { Theme.surface }
                .widgetURL(URL(string: "hearth://plans"))
        }
        .configurationDisplayName("Today")
        .description("The rest of today across every calendar, and invites waiting on you.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

#Preview("Next up", as: .systemSmall) {
    NextUpWidget()
} timeline: {
    HearthEntry(date: WidgetStore.preview.generatedAt, snapshot: WidgetStore.preview)
}

#Preview("Today", as: .systemMedium) {
    TodayWidget()
} timeline: {
    HearthEntry(date: WidgetStore.preview.generatedAt, snapshot: WidgetStore.preview)
}
