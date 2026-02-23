// FamilyControlsManager.swift — ParentGuard iOS
//
// Wraps Apple's FamilyControls framework.
//
// REQUIRES: com.apple.developer.family-controls entitlement (Apple approval)
//   Request at: https://developer.apple.com/contact/request/family-controls-distribution
//
// KEY FRAMEWORKS:
//   FamilyControls    — request authorization to monitor & restrict the device
//   ManagedSettings   — apply restrictions (block apps, limit web content)
//   DeviceActivity    — schedule monitoring intervals (handled in the extension)
//
// IMPORTANT iOS SANDBOXING NOTES:
//   ╔════════════════════════════════════════════════════════════════════════╗
//   ║  iOS does NOT allow reading SMS, call logs, or messages from other   ║
//   ║  apps (WhatsApp, Telegram, iMessage, etc.).  These restrictions are  ║
//   ║  fundamental to iOS security — no entitlement removes them.          ║
//   ║                                                                       ║
//   ║  What ParentGuard CAN do on iOS:                                     ║
//   ║  ✅  Block apps or app categories (ManagedSettings)                  ║
//   ║  ✅  Monitor total time-per-app-category (DeviceActivityMonitor)     ║
//   ║  ✅  Set daily screen time limits (DeviceActivitySchedule)           ║
//   ║  ✅  Enforce bedtime (DeviceActivitySchedule)                        ║
//   ║  ✅  Send push alerts when limits are hit                            ║
//   ║                                                                       ║
//   ║  What ParentGuard CANNOT do on iOS (by design):                     ║
//   ║  ❌  Read SMS or iMessage content                                    ║
//   ║  ❌  Read WhatsApp / Telegram / Discord message content              ║
//   ║  ❌  Access call log                                                 ║
//   ║  ❌  Read notifications from other apps                              ║
//   ╚════════════════════════════════════════════════════════════════════════╝

import SwiftUI
import FamilyControls
import ManagedSettings
import DeviceActivity

@MainActor
final class FamilyControlsManager: ObservableObject {

    static let shared = FamilyControlsManager()

    // ── Published state ───────────────────────────────────────────────────────

    @Published var authorizationStatus: AuthorizationStatus  = .notDetermined
    @Published var isMonitoringActive: Bool                  = false
    @Published var blockedApps: [BlockedApp]                 = []
    @Published var screenTimeLimit: ScreenTimeLimit          = ScreenTimeLimit()
    @Published var errorMessage: String?

    /// The parent's app-picker selection — which apps to block.
    @Published var appSelection: FamilyActivitySelection     = FamilyActivitySelection()

    private let authorizationCenter = AuthorizationCenter.shared
    private let settingsStore        = ManagedSettingsStore()
    private let activityCenter       = DeviceActivityCenter()
    private let prefs                = AppPreferences.shared
    private let repository           = FirebaseRepository.shared

    private var blockedAppsListener: (any ListenerRegistration)?
    private var limitsListener: (any ListenerRegistration)?

    private init() {}

    // ── Authorization ─────────────────────────────────────────────────────────

    /// Request FamilyControls authorization. Must be called from a user gesture.
    /// Shows the iOS system prompt explaining what the app will monitor.
    func requestAuthorization() async {
        do {
            // .individual = monitoring this device only (vs .distribution for families)
            try await authorizationCenter.requestAuthorization(for: .individual)
            authorizationStatus = authorizationCenter.authorizationStatus
            if authorizationStatus == .approved {
                startMonitoring()
            }
        } catch {
            errorMessage = "Authorization failed: \(error.localizedDescription)"
        }
    }

    func checkAuthorizationStatus() {
        authorizationStatus = authorizationCenter.authorizationStatus
    }

    // ── App Blocking ──────────────────────────────────────────────────────────

    /// Apply the current [appSelection] as a device restriction.
    /// This blocks the selected apps immediately using ManagedSettings.
    func applyBlock() {
        guard authorizationStatus == .approved else {
            errorMessage = "FamilyControls not authorized. Complete setup first."
            return
        }

        // Block by application tokens (selected in FamilyActivityPicker UI)
        settingsStore.application.blockedApplications = appSelection.applicationTokens
        // Also block selected activity categories (e.g. Games, Social Networking)
        settingsStore.application.blockedCategories   = appSelection.categoryTokens

        // Enable the shield (lock screen overlay shown when user tries to open blocked app)
        settingsStore.shield.applications             = appSelection.applicationTokens
        settingsStore.shield.applicationCategories   = appSelection.categoryTokens

        isMonitoringActive = true
    }

    /// Remove all restrictions.
    func removeAllBlocks() {
        settingsStore.application.blockedApplications = []
        settingsStore.application.blockedCategories   = []
        settingsStore.shield.applications             = []
        settingsStore.shield.applicationCategories    = []
    }

    /// Sync blocked app list from Firestore and apply restrictions.
    func syncAndApplyBlockedApps() async {
        do {
            let apps = try await repository.fetchBlockedApps()
            blockedApps = apps
            prefs.blockedBundleIdentifiers = apps.map { $0.bundleIdentifier }
            // Note: We can't reconstruct ApplicationTokens from bundle IDs in code;
            // the parent must use the FamilyActivityPicker to select apps.
            // Bundle IDs are stored for the DeviceActivityExtension to use.
        } catch {
            errorMessage = "Failed to sync blocked apps: \(error.localizedDescription)"
        }
    }

    // ── Screen Time Monitoring ────────────────────────────────────────────────

    /// Start the DeviceActivityMonitor for the daily usage schedule.
    /// This causes DeviceActivityMonitorExtension to receive callbacks when
    /// usage thresholds are reached — even when the main app isn't running.
    func startMonitoring() {
        guard authorizationStatus == .approved else { return }

        let schedule = dailySchedule()
        let events   = usageThresholdEvents()

        do {
            try activityCenter.startMonitoring(
                .parentGuardDaily,
                during: schedule,
                events: events
            )
            isMonitoringActive = true
        } catch {
            errorMessage = "Failed to start monitoring: \(error.localizedDescription)"
        }
    }

    func stopMonitoring() {
        activityCenter.stopMonitoring([.parentGuardDaily])
        isMonitoringActive = false
    }

    /// Schedule from midnight to midnight daily (all-day monitoring).
    private func dailySchedule() -> DeviceActivitySchedule {
        var cal     = Calendar.current
        cal.timeZone = TimeZone.current
        let start   = DateComponents(hour: 0, minute: 0)
        let end     = DateComponents(hour: 23, minute: 59)
        return DeviceActivitySchedule(
            intervalStart: start,
            intervalEnd:   end,
            repeats:       true,
            warningTime:   DateComponents(minute: 5)   // 5-min warning before limit
        )
    }

    /// Define threshold events — the extension fires when any of these are hit.
    private func usageThresholdEvents() -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        let limitMins = prefs.dailyLimitMinutes
        let threshold = DateComponents(minute: limitMins)

        // Total screen time threshold (across all apps)
        let totalEvent = DeviceActivityEvent(
            applications: appSelection.applicationTokens,
            threshold:    threshold,
            visibilityInSettings: .visible
        )

        return [.screenTimeLimit: totalEvent]
    }

    // ── Real-time command listeners ───────────────────────────────────────────

    /// Start listening for parent changes to the blocked apps list and screen time limits.
    func startListeningForParentCommands() {
        blockedAppsListener = repository.listenForBlockedAppsChanges { [weak self] apps in
            Task { @MainActor in
                self?.blockedApps = apps
                self?.prefs.blockedBundleIdentifiers = apps.map { $0.bundleIdentifier }
            }
        }

        limitsListener = repository.listenForScreenTimeLimitChanges { [weak self] limit in
            Task { @MainActor in
                self?.screenTimeLimit = limit
                self?.prefs.dailyLimitMinutes = limit.dailyLimitMinutes
                self?.prefs.bedtimeStart      = limit.bedtimeStart
                self?.prefs.bedtimeEnd        = limit.bedtimeEnd
                // Re-start monitoring with updated thresholds
                self?.startMonitoring()
            }
        }
    }

    func stopListeningForParentCommands() {
        blockedAppsListener?.remove()
        limitsListener?.remove()
    }
}

// ─── DeviceActivityName constants ─────────────────────────────────────────────

extension DeviceActivityName {
    static let parentGuardDaily = Self("parentguard.daily")
}

extension DeviceActivityEvent.Name {
    static let screenTimeLimit = Self("parentguard.screentimelimit")
}
