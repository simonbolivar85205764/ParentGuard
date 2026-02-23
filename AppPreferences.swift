// AppPreferences.swift — ParentGuard iOS
// Singleton that wraps UserDefaults in the shared App Group.
//
// WHY SHARED APP GROUP:
//   The DeviceActivityMonitorExtension runs in a separate process. Both the main app
//   and the extension need to read familyId/childId to upload to Firebase.
//   Standard UserDefaults are per-process; the shared group (group.com.parentguard.monitor)
//   is accessible to both.
//
//   Configure the App Group in Xcode → Signing & Capabilities → App Groups for BOTH
//   the main app target and the DeviceActivityExtension target.

import Foundation

final class AppPreferences {

    static let shared = AppPreferences()

    /// The Suite name must match the App Group identifier in your entitlements.
    private let defaults: UserDefaults = {
        guard let d = UserDefaults(suiteName: "group.com.parentguard.monitor") else {
            fatalError("App Group 'group.com.parentguard.monitor' not configured. " +
                       "Add it in Xcode → Signing & Capabilities → App Groups for both targets.")
        }
        return d
    }()

    private init() {}

    // ── Identity ──────────────────────────────────────────────────────────────

    /// The parent's Firebase UID — entered during setup as the "Family Code".
    var familyId: String {
        get { defaults.string(forKey: "family_id") ?? "" }
        set { defaults.set(newValue, forKey: "family_id") }
    }

    /// The child device's Firebase UID — auto-generated on first launch.
    var childId: String {
        get {
            if let id = defaults.string(forKey: "child_id"), !id.isEmpty { return id }
            let id = UUID().uuidString
            defaults.set(id, forKey: "child_id")
            return id
        }
        set { defaults.set(newValue, forKey: "child_id") }
    }

    var childName: String {
        get { defaults.string(forKey: "child_name") ?? "Child" }
        set { defaults.set(newValue, forKey: "child_name") }
    }

    var isSetupComplete: Bool {
        get { defaults.bool(forKey: "setup_complete") }
        set { defaults.set(newValue, forKey: "setup_complete") }
    }

    // ── Sync state ────────────────────────────────────────────────────────────

    var lastUsageSync: Date {
        get { defaults.object(forKey: "last_usage_sync") as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: "last_usage_sync") }
    }

    var lastProfileSync: Date {
        get { defaults.object(forKey: "last_profile_sync") as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: "last_profile_sync") }
    }

    // ── Blocked apps cache (written by app, read by extension) ───────────────

    /// Stores an array of bundle identifiers the parent has blocked.
    /// The DeviceActivityMonitorExtension reads this to decide what to restrict.
    var blockedBundleIdentifiers: [String] {
        get { defaults.stringArray(forKey: "blocked_bundle_ids") ?? [] }
        set { defaults.set(newValue, forKey: "blocked_bundle_ids") }
    }

    // ── Screen time settings ──────────────────────────────────────────────────

    var dailyLimitMinutes: Int {
        get { defaults.integer(forKey: "daily_limit_mins").nonZero(default: 120) }
        set { defaults.set(newValue, forKey: "daily_limit_mins") }
    }

    var bedtimeStart: String {
        get { defaults.string(forKey: "bedtime_start") ?? "21:00" }
        set { defaults.set(newValue, forKey: "bedtime_start") }
    }

    var bedtimeEnd: String {
        get { defaults.string(forKey: "bedtime_end") ?? "07:00" }
        set { defaults.set(newValue, forKey: "bedtime_end") }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    func clearAll() {
        let keysToKeep = ["family_id", "child_id"]   // preserve identity across re-setup
        defaults.dictionaryRepresentation().keys.forEach { key in
            if !keysToKeep.contains(key) { defaults.removeObject(forKey: key) }
        }
    }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

private extension Int {
    func nonZero(default fallback: Int) -> Int { self == 0 ? fallback : self }
}
