// ParentGuardApp.swift — ParentGuard iOS
// App entry point. Configures Firebase, registers background tasks,
// and routes to Setup or Dashboard based on setup state.

import SwiftUI
import Firebase
import BackgroundTasks
import UserNotifications

@main
struct ParentGuardApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var familyManager = FamilyControlsManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(familyManager)
        }
    }
}

// ─── Root View ────────────────────────────────────────────────────────────────

struct RootView: View {
    @EnvironmentObject var familyManager: FamilyControlsManager
    @State private var isSetupComplete = AppPreferences.shared.isSetupComplete

    var body: some View {
        Group {
            if isSetupComplete {
                ContentView()
            } else {
                SetupView(onComplete: {
                    isSetupComplete = true
                })
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .setupDidComplete)) { _ in
            isSetupComplete = true
        }
    }
}

extension Notification.Name {
    static let setupDidComplete = Notification.Name("pg.setupDidComplete")
}

// ─── AppDelegate ──────────────────────────────────────────────────────────────

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 1. Configure Firebase first (other singletons depend on it)
        FirebaseApp.configure()

        // 2. Register BGTask identifiers — MUST happen before the app finishes launching
        BackgroundTaskManager.shared.registerTasks()

        // 3. Request notification permission (for parent alerts on the parent's device)
        //    On the child's device this shows "Screen time ending soon" warnings
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            if granted {
                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()  // silent push support
                }
            }
        }

        // 4. If setup is already complete, start listening for parent commands
        if AppPreferences.shared.isSetupComplete {
            FamilyControlsManager.shared.startListeningForParentCommands()
            FamilyControlsManager.shared.checkAuthorizationStatus()
        }

        return true
    }

    // ── Background transition ──────────────────────────────────────────────────

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Schedule both task types every time we go to background.
        // iOS guarantees at least one of these will fire before the next time
        // the user opens the app — maintaining a sync heartbeat.
        BackgroundTaskManager.shared.scheduleAppRefresh()
        BackgroundTaskManager.shared.scheduleProcessingTask()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Sync blocked apps and screen time limits whenever the app comes to foreground
        if AppPreferences.shared.isSetupComplete {
            Task {
                await FamilyControlsManager.shared.syncAndApplyBlockedApps()
            }
        }
    }

    // ── Remote notifications (silent push) ────────────────────────────────────

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Silent push from the parent dashboard → perform a short sync immediately
        Task {
            do {
                try await performSilentPushSync()
                completionHandler(.newData)
            } catch {
                completionHandler(.failed)
            }
        }
    }

    private func performSilentPushSync() async throws {
        // Re-use the short sync logic from BackgroundTaskManager
        let bgt = BackgroundTaskManager.shared
        // Internal: schedule a one-shot sync via the existing infrastructure
        // (In production, expose a performShortSync() method or duplicate the logic)
        bgt.scheduleAppRefresh()
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // Forward token to Firebase Messaging for push support
        // Messaging.messaging().apnsToken = deviceToken
    }

    // ── UNUserNotificationCenterDelegate ─────────────────────────────────────

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])  // show notifications even when app is open
    }
}
