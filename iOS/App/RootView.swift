import HearthCore
import HearthKit
import SwiftUI

enum AppTab: String, Hashable, CaseIterable {
    case today
    case inbox
    case plans
    case people
    case ask
}

/// Where the Today header and deep links can take you.
enum Destination: Hashable {
    case signals
    case sources
}

/// The five tabs from the design.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var tab: AppTab = .today
    @State private var showCapture = false
    @State private var todayPath: [Destination] = []

    var body: some View {
        TabView(selection: $tab) {
            Tab("Today", systemImage: "sun.max", value: AppTab.today) {
                NavigationStack(path: $todayPath) {
                    TodayView(tab: $tab, showCapture: $showCapture, path: $todayPath)
                        .navigationDestination(for: Destination.self) { destination in
                            switch destination {
                            case .signals: SignalsPlaceholder()
                            case .sources: SourcesView()
                            }
                        }
                }
            }
            Tab("Inbox", systemImage: "tray", value: AppTab.inbox) {
                NavigationStack { InboxPlaceholder() }
            }
            Tab("Plans", systemImage: "calendar", value: AppTab.plans) {
                NavigationStack { PlansView(showCapture: $showCapture) }
            }
            Tab("People", systemImage: "heart", value: AppTab.people) {
                NavigationStack { PeoplePlaceholder() }
            }
            Tab("Ask", systemImage: "ellipsis.bubble", value: AppTab.ask) {
                NavigationStack { AskPlaceholder() }
            }
        }
        .sheet(isPresented: $showCapture) { CapturePlaceholder() }
        .onOpenURL { url in open(url) }
        .task { await app.refreshAll() }
    }

    /// `hearth://plans`, `hearth://today`, `hearth://sources`, `hearth://inbox`.
    func open(_ url: URL) {
        guard url.scheme == "hearth" else { return }
        switch url.host {
        case "plans": tab = .plans
        case "inbox": tab = .inbox
        case "ask": tab = .ask
        case "people": tab = .people
        case "sources":
            tab = .today
            todayPath = [.sources]
        default: tab = .today
        }
    }
}
