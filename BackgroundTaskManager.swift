// BackgroundTaskManager.swift — ParentGuard iOS
//
// HOW iOS BACKGROUND EXECUTION WORKS:
// ─────────────────────────────────────
// Unlike Android's foreground service (which runs continuously), iOS apps are
// suspended when backgrounded. Background work happens through:
//
//  1. BGAppRefreshTask ("com.parentguard.monitor.sync")
//     • Short-lived: ~30 seconds of runtime
//     • Frequency: system-managed (~15 min minimum, often longer)
//     • Use: upload device profile heartbeat, sync blocked app list
//
//  2. BGProcessingTask ("com.parentguard.monitor.longsync")
//     • Longer-lived: several minutes
//     • Triggers: typically when plugged in + screen off
//     • Use: batch upload of usage records, cleanup
//
//  3. DeviceActivityMonitorExtension (separate process)
//     • Completely separate from the app process
//     • Receives callbacks when usage thresholds are hit
//     • Can send notifications and upload alerts without the app running
//     • This is the PRIMARY background mechanism for enforcement
//
//  4. Silent Push Notifications
//     • The parent dashboard can trigger a silent push that wakes the app
//     • Gives ~30 seconds of background time
//     • Used for: "fetch latest blocked apps" command from parent
//
// Both BGTask identifiers MUST be declared in Info.plist under
// BGTaskSchedulerPermittedIdentifiers — see Info.plist.

import Foundation
import BackgroundTasks
import FirebaseAuth
import UIKit

final class BackgroundTaskManager {

    static let shared = BackgroundTaskManager()

    private let appRefreshId   = "com.parentguard.monitor.sync"
    private let processingId   = "com.parentguard.monitor.longsync"
    private let prefs          = AppPreferences.shared
    private let repository     = FirebaseRepository.shared

    private init() {}

    // ── Registration (call from AppDelegate.application(_:didFinishLaunchingWithOptions:)) ──

    func registerTasks() {
        // App refresh: short sync, runs often
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: appRefreshId,
            using: .main
        ) { [weak self] task in
            self?.handleAppRefresh(task: task as! BGAppRefreshTask)
        }

        // Processing: longer sync, runs when idle/plugged in
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: processingId,
            using: .main
        ) { [weak self] task in
            self?.handleProcessingTask(task: task as! BGProcessingTask)
        }
    }

    // ── Scheduling (call when app goes to background) ─────────────────────────

    /// Schedule the next app refresh. Always re-schedule after running to maintain
    /// the chain — if you don't schedule inside the handler, iOS stops waking you.
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: appRefreshId)
        // Earliest date: 15 minutes from now. System may delay longer.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // BGTaskSchedulerErrorCodeTooManyPendingTaskRequests is common if already scheduled
            // BGTaskSchedulerErrorCodeNotPermitted means BGTaskSchedulerPermittedIdentifiers is wrong
            print("[BGTask] scheduleAppRefresh failed: \(error.localizedDescription)")
        }
    }

    /// Schedule a longer processing task for the next idle/charging window.
    func scheduleProcessingTask() {
        let request = BGProcessingTaskRequest(identifier: processingId)
        request.earliestBeginDate    = Date(timeIntervalSinceNow: 60 * 60)  // 1 hour
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower       = false  // run on battery too

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[BGTask] scheduleProcessingTask failed: \(error.localizedDescription)")
        }
    }

    // ── Handlers ──────────────────────────────────────────────────────────────

    private func handleAppRefresh(task: BGAppRefreshTask) {
        // Immediately schedule the next one to maintain the chain
        scheduleAppRefresh()

        let taskHandle = Task {
            do {
                try await performShortSync()
                task.setTaskCompleted(success: true)
            } catch {
                print("[BGTask] App refresh failed: \(error.localizedDescription)")
                task.setTaskCompleted(success: false)
            }
        }

        // If iOS cancels the task (time expired), cancel our coroutine
        task.expirationHandler = {
            taskHandle.cancel()
        }
    }

    private func handleProcessingTask(task: BGProcessingTask) {
        scheduleProcessingTask()

        let taskHandle = Task {
            do {
                try await performShortSync()
                try await performLongSync()
                task.setTaskCompleted(success: true)
            } catch {
                print("[BGTask] Processing task failed: \(error.localizedDescription)")
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            taskHandle.cancel()
        }
    }

    // ── Sync logic ────────────────────────────────────────────────────────────

    /// Short sync (~5–10 seconds): heartbeat + fetch latest parent commands.
    private func performShortSync() async throws {
        guard !prefs.familyId.isEmpty, !prefs.childId.isEmpty else { return }

        // Upload device heartbeat
        let profile = DeviceProfile(
            childName:  prefs.childName,
            deviceModel: UIDevice.current.model,
            iosVersion:  UIDevice.current.systemVersion,
            isOnline:   true,
            platform:   "ios"
        )
        try await repository.uploadDeviceProfile(profile)
        prefs.lastProfileSync = Date()

        // Fetch latest blocked apps and screen time limits from Firestore
        async let blockedApps   = repository.fetchBlockedApps()
        async let screenLimits  = repository.fetchScreenTimeLimits()

        let (apps, limits) = try await (blockedApps, screenLimits)

        prefs.blockedBundleIdentifiers = apps.map { $0.bundleIdentifier }
        prefs.dailyLimitMinutes        = limits.dailyLimitMinutes
        prefs.bedtimeStart             = limits.bedtimeStart
        prefs.bedtimeEnd               = limits.bedtimeEnd
    }

    /// Long sync (several minutes): upload batched usage data.
    private func performLongSync() async throws {
        // Collect and upload today's app usage records.
        // DeviceActivityMonitorExtension writes usage summaries to shared defaults;
        // we read them here and batch-upload to Firestore.
        let usageRecords = collectUsageFromSharedDefaults()
        if !usageRecords.isEmpty {
            try await repository.uploadAppUsage(usageRecords)
            prefs.lastUsageSync = Date()
        }
    }

    /// Read usage summaries that the DeviceActivityMonitorExtension wrote
    /// to the shared App Group UserDefaults.
    private func collectUsageFromSharedDefaults() -> [AppUsageRecord] {
        guard let data = AppPreferences.shared.defaults?.data(forKey: "usage_records_today"),
              let records = try? JSONDecoder().decode([AppUsageRecord].self, from: data) else {
            return []
        }
        return records
    }
}

// ─── UserDefaults extension to expose shared defaults ─────────────────────────

extension AppPreferences {
    // Expose the underlying UserDefaults for BackgroundTaskManager to read directly.
    var defaults: UserDefaults? {
        UserDefaults(suiteName: "group.com.parentguard.monitor")
    }
}
