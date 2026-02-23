// MonitorExtension.swift — DeviceActivityMonitorExtension target
//
// This file belongs to the SEPARATE "DeviceActivityExtension" Xcode target,
// NOT the main ParentGuard app target.
//
// HOW TO ADD THIS EXTENSION IN XCODE:
//   1. File → New → Target
//   2. Choose "Device Activity Monitor Extension"
//   3. Name it "DeviceActivityExtension"
//   4. Add the App Group "group.com.parentguard.monitor" to its entitlements
//   5. Add the com.apple.developer.family-controls entitlement
//   6. Add FirebaseFirestore and FirebaseAuth via the extension's Package Dependencies
//
// WHY A SEPARATE PROCESS:
//   DeviceActivityMonitor callbacks run in a sandboxed extension process that is
//   launched by the system — separately from the main app — even when the app is
//   killed. This gives us true background execution for enforcement: blocking apps
//   and alerting parents happens without the app being open.
//
// WHAT THIS EXTENSION DOES:
//   • intervalDidStart  — daily monitoring period begins (midnight)
//   • intervalDidEnd    — daily monitoring period ends (11:59 PM); upload day's usage
//   • eventDidReachThreshold — screen time limit hit; block all apps + send alert
//   • intervalWillStartWarning — 5 minutes before period ends; warn the child

import DeviceActivity
import ManagedSettings
import UserNotifications
import Foundation
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore

// ─── Extension Entry Point ────────────────────────────────────────────────────

@main
struct MonitorExtensionApp: DeviceActivityApp {
    var body: some Scene {
        DeviceActivityReportScene { _ in
            MonitorExtension()
        }
    }
}

// ─── Monitor Implementation ───────────────────────────────────────────────────

class MonitorExtension: DeviceActivityMonitor {

    private let store  = ManagedSettingsStore()
    private let prefs  = SharedPreferences()   // reads from App Group UserDefaults
    private var db: Firestore?
    private var auth: Auth?

    // Called once per extension launch — configure Firebase here since the extension
    // is a separate process that doesn't inherit the main app's Firebase config.
    override init() {
        super.init()
        configureFirebase()
    }

    private func configureFirebase() {
        if FirebaseApp.app() == nil {
            // GoogleService-Info.plist must also be added to the Extension target
            FirebaseApp.configure()
        }
        db   = Firestore.firestore()
        auth = Auth.auth()
    }

    // ── DeviceActivityMonitor callbacks ───────────────────────────────────────

    /// A new monitoring interval has started (every midnight).
    /// Reset yesterday's counters, re-apply restrictions for the new day.
    override func intervalDidStart(for activity: DeviceActivityName) {
        guard activity == .parentGuardDaily else { return }
        // Re-apply any blocks that were set — they persist across days but
        // we refresh here in case Firestore had updates while the extension was idle.
        reapplyBlocksFromLocalCache()
    }

    /// The daily interval has ended (11:59 PM). Upload the day's usage summary.
    override func intervalDidEnd(for activity: DeviceActivityName) {
        guard activity == .parentGuardDaily else { return }
        uploadDailyUsageSummary()
    }

    /// A usage threshold event was reached (e.g. daily screen time limit hit).
    /// This is the most important callback: enforce the limit immediately.
    override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        guard activity == .parentGuardDaily else { return }

        switch event {
        case .screenTimeLimit:
            enforceScreenTimeLimit()
            sendAlertToParent(type: "SCREEN_TIME_LIMIT",
                              message: "\(prefs.childName)'s daily screen time limit was reached.")

        default:
            break
        }
    }

    /// Called 5 minutes before the daily interval ends (the warning time we configured).
    override func intervalWillStartWarning(for activity: DeviceActivityName) {
        // Send a gentle in-device notification to the child: "5 minutes left today"
        scheduleLocalNotification(
            title: "Screen time ending soon",
            body:  "You have 5 minutes left on your device today."
        )
    }

    // ── Enforcement ───────────────────────────────────────────────────────────

    /// Lock the device by shielding all apps. Uses ManagedSettings to prevent
    /// opening any app (except Safari-safe mode and Phone, which can't be blocked).
    private func enforceScreenTimeLimit() {
        // Shield all applications (shows a "Time's Up" overlay)
        store.shield.applicationCategories = .all()
        // Block web content
        store.webContent.blockedByFilter    = .all()
    }

    private func reapplyBlocksFromLocalCache() {
        // Re-apply any per-app blocks that were active before the extension was suspended
        // The app tokens are opaque to us without the picker; we use category-level blocking
        // for scheduled blocks.  Per-app blocking requires the FamilyActivityPicker UI
        // in the main app — those tokens are already applied via ManagedSettingsStore
        // which persists independently.
    }

    // ── Firestore upload ──────────────────────────────────────────────────────

    private func uploadDailyUsageSummary() {
        // Read cached usage from the shared App Group defaults
        guard let data = UserDefaults(suiteName: "group.com.parentguard.monitor")?
            .data(forKey: "usage_records_today"),
              let records = try? JSONDecoder().decode([AppUsageRecord].self, from: data)
        else { return }

        guard !records.isEmpty else { return }

        let familyId = prefs.familyId
        let childId  = prefs.childId
        guard !familyId.isEmpty, !childId.isEmpty, let db else { return }

        // Batch write up to 400 records
        for chunk in records.chunked(into: 400) {
            let batch = db.batch()
            for record in chunk {
                let docId = "\(record.date)_\(record.bundleIdentifier)"
                let ref   = db.collection("families").document(familyId)
                    .collection("children").document(childId)
                    .collection("appUsage").document(docId)
                if let data = try? Firestore.Encoder().encode(record) {
                    batch.setData(data, forDocument: ref, merge: true)
                }
            }
            batch.commit { error in
                if let error { print("[Extension] Usage upload failed: \(error)") }
            }
        }
    }

    private func uploadAlert(type: String, message: String) {
        let familyId = prefs.familyId
        let childId  = prefs.childId
        guard !familyId.isEmpty, !childId.isEmpty, let db else { return }

        let alert: [String: Any] = [
            "id":        UUID().uuidString,
            "type":      type,
            "message":   message,
            "timestamp": Timestamp(date: Date()),
            "isRead":    false,
            "platform":  "ios"
        ]

        db.collection("families").document(familyId)
            .collection("children").document(childId)
            .collection("alerts").addDocument(data: alert) { error in
                if let error { print("[Extension] Alert upload failed: \(error)") }
            }
    }

    private func sendAlertToParent(type: String, message: String) {
        uploadAlert(type: type, message: message)
        // Also schedule a local notification on this device for the child
        scheduleLocalNotification(title: "Screen time limit reached", body: message)
    }

    // ── Local notifications ───────────────────────────────────────────────────

    private func scheduleLocalNotification(title: String, body: String) {
        let content             = UNMutableNotificationContent()
        content.title           = title
        content.body            = body
        content.sound           = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content:    content,
            trigger:    trigger
        )

        UNUserNotificationCenter.current().add(request)
    }
}

// ─── Lightweight shared prefs for the extension ───────────────────────────────

/// The extension cannot import AppPreferences from the main target,
/// so this is a minimal duplicate that reads from the same shared suite.
struct SharedPreferences {
    private let defaults = UserDefaults(suiteName: "group.com.parentguard.monitor")

    var familyId:  String { defaults?.string(forKey: "family_id")  ?? "" }
    var childId:   String { defaults?.string(forKey: "child_id")   ?? "" }
    var childName: String { defaults?.string(forKey: "child_name") ?? "Child" }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
