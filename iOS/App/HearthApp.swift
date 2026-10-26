import BackgroundTasks
import HearthCore
import SwiftUI

@main
struct HearthApp: App {
    static let refreshTask = "com.joshmiller83.hearth.refresh"

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppEnvironment.makeModel()
        _model = State(initialValue: model)
        // A push can wake the app before any window exists.
        AppDelegate.model = model
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.ember)
                .task {
                    if LaunchMode.current() == .live, !LaunchMode.isTestHost { await Notifications.refreshRegistration() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                AppDatabase.resume()
                Task { await model.refreshAll() }
            case .background:
                // Let go of the shared database before iOS suspends us (0xdead10cc).
                AppDatabase.suspend()
                Self.scheduleRefresh()
            default:
                break
            }
        }
        // iOS wakes the app now and then; keep Today and the StandBy widgets current.
        .backgroundTask(.appRefresh(Self.refreshTask)) {
            AppDatabase.resume()
            await model.refreshAll()
            AppDatabase.suspend()
            await Self.scheduleRefresh()
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
