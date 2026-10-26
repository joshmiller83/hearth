import HearthCore
import SwiftUI

@main
struct HearthApp: App {
    @State private var model = AppEnvironment.makeModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.ember)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                AppDatabase.resume()
                Task { await model.refreshAll() }
            case .background:
                // Let go of the shared database before iOS suspends us (0xdead10cc).
                AppDatabase.suspend()
            default:
                break
            }
        }
    }
}
