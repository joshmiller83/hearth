import HearthCore
import SwiftUI
import UIKit
import UserNotifications

/// UIKit's push callbacks, handed to the app model.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set by HearthApp at launch, before any push can arrive.
    @MainActor static var model: AppModel?

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            // Xcode installs talk to the APNs sandbox.
            #if DEBUG
            let environment = "development"
            #else
            let environment = "production"
            #endif
            await AppDelegate.model?.registerForPush(token: deviceToken, environment: environment)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {}

    /// A push woke the app (the brief, a reply that went out): refresh, so Today
    /// and the StandBy widgets are current before anyone looks.
    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            guard let model = AppDelegate.model else { return completionHandler(.noData) }
            AppDatabase.resume()
            await model.refreshAll()
            // Let go of the shared database again if we're still in the background (0xdead10cc).
            if UIApplication.shared.applicationState == .background { AppDatabase.suspend() }
            completionHandler(.newData)
        }
    }

    /// Show Hearth's pushes even while it's open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

/// Asking for notifications, once the owner taps.
@MainActor
enum Notifications {
    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks (the first time), then registers with APNs so the relay can push.
    static func enable() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        return granted
    }

    /// Re-registers on launch when already allowed (tokens can change).
    static func refreshRegistration() async {
        if await status() == .authorized { UIApplication.shared.registerForRemoteNotifications() }
    }
}
