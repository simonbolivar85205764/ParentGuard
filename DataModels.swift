// DataModels.swift — ParentGuard iOS
// Mirrors the Kotlin data classes in the Android app.
// Both platforms share the same Firestore schema, so field names must match exactly.

import Foundation
import FirebaseFirestore

// ─── Device Profile ───────────────────────────────────────────────────────────

struct DeviceProfile: Codable {
    var childName: String      = ""
    var deviceModel: String    = ""
    var iosVersion: String     = ""
    var lastSync: Timestamp    = Timestamp(date: Date())
    var batteryLevel: Int      = 0
    var isOnline: Bool         = false
    var platform: String       = "ios"
}

// ─── App Usage ────────────────────────────────────────────────────────────────

/// One record per app per day. Uploaded by DeviceActivityMonitorExtension and SyncWorker.
struct AppUsageRecord: Codable, Identifiable {
    var id: String             { "\(date)_\(bundleIdentifier.replacingOccurrences(of: ".", with: "_"))" }
    var bundleIdentifier: String = ""
    var appName: String          = ""
    var categoryToken: String    = ""    // DeviceActivity category (Apple doesn't expose bundle IDs to extension)
    var totalTimeSeconds: Int    = 0
    var lastUsed: Timestamp      = Timestamp(date: Date())
    var date: String             = ""    // yyyy-MM-dd
    var platform: String         = "ios"
}

// ─── App Blocking ─────────────────────────────────────────────────────────────

/// A blocked app entry, written by the parent dashboard and read by the child device.
struct BlockedApp: Codable, Identifiable {
    var id: String               { bundleIdentifier }
    var bundleIdentifier: String = ""
    var appName: String          = ""
    var categoryToken: String    = ""    // for blocking by category
    var blockedBy: String        = ""    // parent UID
    var blockedAt: Timestamp     = Timestamp(date: Date())
    var scheduleStart: String    = ""    // "HH:mm"
    var scheduleEnd: String      = ""    // "HH:mm"
    var blockAllDay: Bool        = false
}

// ─── Screen Time Limits ───────────────────────────────────────────────────────

struct ScreenTimeLimit: Codable {
    var dailyLimitMinutes: Int   = 120
    var bedtimeStart: String     = "21:00"
    var bedtimeEnd: String       = "07:00"
    var weekendLimitMinutes: Int = 180
}

// ─── Alerts ───────────────────────────────────────────────────────────────────

struct AlertRecord: Codable, Identifiable {
    var id: String               = UUID().uuidString
    var type: AlertType          = .appBlocked
    var message: String          = ""
    var timestamp: Timestamp     = Timestamp(date: Date())
    var isRead: Bool             = false
    var platform: String         = "ios"

    enum AlertType: String, Codable {
        case appBlocked        = "APP_BLOCKED"
        case screenTimeLimitHit = "SCREEN_TIME_LIMIT"
        case bedtimeViolation  = "BEDTIME"
        case usageThreshold    = "USAGE_THRESHOLD"
    }
}

// ─── Usage Summary (local, not uploaded directly) ─────────────────────────────

/// A lightweight struct used in the dashboard UI to display today's usage.
struct AppUsageSummary: Identifiable {
    var id: String               = UUID().uuidString
    var appName: String          = ""
    var bundleIdentifier: String = ""
    var totalMinutes: Int        = 0
    var isBlocked: Bool          = false
}

// ─── Upload Queue Entry ───────────────────────────────────────────────────────

/// Used to persist upload queue between app launches in the shared App Group.
struct QueuedUpload: Codable {
    var id: String               = UUID().uuidString
    var collection: String       = ""  // e.g. "appUsage", "alerts"
    var documentId: String       = ""
    var data: [String: String]   = [:]
    var createdAt: Date          = Date()
    var attemptCount: Int        = 0
}
