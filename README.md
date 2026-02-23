# 🛡️ ParentGuard — Android & iOS

**Transparent, consent-based parental monitoring. Native apps for both platforms sharing a single Firebase backend.**

---

## Platform Comparison

| Capability | Android | iOS |
|---|:---:|:---:|
| SMS message content | ✅ | ❌ |
| Call log | ✅ | ❌ |
| WhatsApp / Telegram / Discord messages | ✅ | ❌ |
| App usage time | ✅ | ✅ |
| Block specific apps | ✅ | ✅ |
| Block app categories | ✅ | ✅ |
| Daily screen time limit | ✅ | ✅ |
| Bedtime enforcement | ✅ | ✅ |
| Real-time push alerts to parent | ✅ | ✅ |
| Background execution | Foreground service + WorkManager | BGTask + DeviceActivityMonitor extension |
| Runs after device restart | ✅ BootReceiver | ✅ BGTask auto-reschedules |
| Survives battery optimizer | ✅ WorkManager backstop | ✅ BGTask + extension is separate process |

> **Why the difference?** iOS sandboxing is fundamental to Apple's security model.  
> No entitlement or API exists to read SMS, call logs, or other apps' messages on iOS — by design.  
> The Android version uses `READ_SMS`, `READ_CALL_LOG`, `NotificationListenerService`, and `AccessibilityService`, none of which exist on iOS.  
> For full message monitoring, Android is required.

---

## Repository Structure

```
ParentGuard/
├── ParentGuard-Android/          ← Kotlin / Android Studio project
│   ├── app/
│   │   ├── build.gradle
│   │   └── src/main/
│   │       ├── AndroidManifest.xml
│   │       └── java/com/parentguard/monitor/
│   │           ├── DataModels.kt
│   │           ├── AppPreferences.kt
│   │           ├── DataCollectors.kt            — SMS, calls, app usage
│   │           ├── FirebaseRepository.kt
│   │           ├── MonitoringService.kt          — Foreground service (continuous)
│   │           ├── SyncWorker.kt                 — WorkManager backstop
│   │           ├── MessagingNotificationListener.kt — 3rd-party app messages (incoming)
│   │           ├── AppReadingAccessibilityService.kt — 3rd-party app messages (sent)
│   │           ├── AppBlockerAccessibilityService.kt — App blocking
│   │           ├── Receivers.kt                  — SMS real-time + Boot
│   │           ├── SetupActivity.kt
│   │           └── AppBlockedActivity.kt
│   └── parent-dashboard.html
│
├── ParentGuard-iOS/              ← Swift / Xcode project
│   ├── Package.swift
│   ├── Info.plist
│   ├── ParentGuard.entitlements
│   ├── ParentGuardApp.swift      — Entry point, AppDelegate, background registration
│   ├── Core/
│   │   ├── DataModels.swift
│   │   ├── AppPreferences.swift  — Shared App Group UserDefaults
│   │   ├── BackgroundTaskManager.swift — BGTaskScheduler
│   │   ├── FamilyControlsManager.swift — FamilyControls + ManagedSettings
│   │   └── FirebaseRepository.swift
│   ├── Views/
│   │   ├── ContentView.swift     — Tab navigation + all dashboard views
│   │   └── SetupView.swift       — 4-step onboarding wizard
│   └── DeviceActivityExtension/
│       └── MonitorExtension.swift — Separate extension process (always-on enforcement)
│
└── README.md                     ← This file
```

---

## Shared Firebase Backend

Both apps write to the same Firestore project. The schema is designed so the parent dashboard (`parent-dashboard.html`) can read data from either platform transparently.

```
families/
  {parentUid}/
    children/
      {childUid}/
        profile/info              — DeviceProfile (platform field: "android" or "ios")
        appUsage/{date_pkg}       — AppUsageRecord
        appMessages/{id}          — AppMessage (Android only)
        sms/{id}                  — SmsRecord (Android only)
        calls/{id}                — CallRecord (Android only)
        alerts/{id}               — AlertRecord (both platforms)
        blockedApps/{pkg}         — BlockedApp (parent writes → child reads)
        screenTimeLimits/limits   — ScreenTimeLimit (parent writes → child reads)
```

### Firestore Security Rules

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    // Parent reads everything in their family
    match /families/{familyId}/children/{childId}/{document=**} {
      allow read: if request.auth != null && request.auth.uid == familyId;
    }

    // Child writes its own monitoring data
    match /families/{familyId}/children/{childId}/sms/{doc} {
      allow write: if request.auth != null && request.auth.uid == childId;
    }
    match /families/{familyId}/children/{childId}/calls/{doc} {
      allow write: if request.auth != null && request.auth.uid == childId;
    }
    match /families/{familyId}/children/{childId}/appMessages/{doc} {
      allow write: if request.auth != null && request.auth.uid == childId;
    }
    match /families/{familyId}/children/{childId}/appUsage/{doc} {
      allow write: if request.auth != null && request.auth.uid == childId;
    }
    match /families/{familyId}/children/{childId}/profile/{doc} {
      allow write: if request.auth != null && request.auth.uid == childId;
    }
    match /families/{familyId}/children/{childId}/alerts/{doc} {
      allow write: if request.auth != null && request.auth.uid == childId;
    }

    // Parent writes controls; child only reads them
    match /families/{familyId}/children/{childId}/blockedApps/{doc} {
      allow read:  if request.auth != null && request.auth.uid == childId;
      allow write: if request.auth != null && request.auth.uid == familyId;
    }
    match /families/{familyId}/children/{childId}/screenTimeLimits/{doc} {
      allow read:  if request.auth != null && request.auth.uid == childId;
      allow write: if request.auth != null && request.auth.uid == familyId;
    }
  }
}
```

---

## Background Execution — How Each Platform Stays Alive

### Android

Android gives apps more background latitude than iOS. ParentGuard uses a **two-layer** strategy so monitoring survives even aggressive battery optimizers (Xiaomi, Huawei, Samsung power-saving modes):

```
Layer 1 — Foreground Service (MonitoringService.kt)
  • Runs continuously as a foreground service
  • Android requires a persistent notification (visible to child — by design)
  • START_STICKY: system restarts it automatically if killed
  • BootReceiver: restarts it after device reboot
  • Sync loop: SMS/calls every 15 min, app usage every 1 hour

Layer 2 — WorkManager (SyncWorker.kt)
  • Scheduled by MonitoringService on start AND by BootReceiver on boot
  • Runs every 15 minutes via the Android OS job scheduler
  • If Layer 1 is killed, SyncWorker fires and re-starts MonitoringService
  • Constrained to network-connected windows; retries with back-off on failure
  • SyncWorker.schedulePeriodicSync(context) is idempotent — safe to call repeatedly

Layer 3 — BroadcastReceiver (SmsReceiver.kt)
  • Intercepts incoming SMS in real-time regardless of service state
  • Uploads immediately to Firebase on a short-lived IO coroutine
```

**Battery optimizer note:** Go to Settings → Battery → Battery optimisation on the child's device and set ParentGuard to "Don't optimise". On Samsung: also enable it in Settings → Device Care → Battery → Background usage limits. On Xiaomi: Settings → Apps → Manage apps → ParentGuard → Battery saver → No restrictions + enable Autostart.

### iOS

iOS suspends apps when they enter the background. Background execution is system-managed and time-limited. ParentGuard uses **three mechanisms**:

```
Mechanism 1 — BGAppRefreshTask ("com.parentguard.monitor.sync")
  • Registered in AppDelegate, declared in Info.plist
  • Scheduled every time the app backgrounds: scheduleAppRefresh()
  • System decides when to actually run (typically ~15–30 min, may be longer)
  • ~30 seconds of execution time
  • Performs: heartbeat upload + fetch updated blocked apps + screen time limits
  • Always re-schedules itself to maintain the chain

Mechanism 2 — BGProcessingTask ("com.parentguard.monitor.longsync")
  • Runs when device is idle, often plugged in
  • Several minutes of execution time
  • Performs: batch upload of usage records
  • Also re-schedules itself

Mechanism 3 — DeviceActivityMonitorExtension (MOST IMPORTANT)
  • A SEPARATE PROCESS — runs independently of the main app
  • Launched by the system when usage thresholds are reached
  • Receives intervalDidStart, intervalDidEnd, eventDidReachThreshold callbacks
  • Enforces restrictions (shields apps) and uploads alerts WITHOUT the app running
  • This is why iOS monitoring works even when the app is killed
  • The extension shares data with the main app via a shared App Group
```

**iOS limitation:** The system decides when BGTasks run. You cannot guarantee a precise 15-minute interval. DeviceActivityMonitor is the reliable always-on component; BGTask is for data sync.

---

## Android Setup Guide

### Prerequisites
- Android Studio Hedgehog (2023.1.1) or newer
- Android 8.0+ (API 26) on the child's device

### 1. Firebase Project
1. Create a Firebase project at [console.firebase.google.com](https://console.firebase.google.com)
2. Enable Authentication → Email/Password
3. Create Firestore in production mode
4. Download `google-services.json` → place in `ParentGuard-Android/app/`
5. Apply the security rules above

### 2. Build
```bash
cd ParentGuard-Android
./gradlew assembleDebug
# Output: app/build/outputs/apk/debug/app-debug.apk
```

### 3. Install on Child's Device (parent-run)
1. Enable "Install unknown apps" on the child's device
2. Install the APK
3. Run the setup wizard — it guides through:
   - Entering the Family Code (parent's Firebase UID)
   - Runtime permissions (SMS, Call Log, Contacts, Notifications)
   - Usage Access (system settings)
   - Notification Access (for WhatsApp, Telegram, Discord, etc.)
   - Two Accessibility Services (App Blocker + Message Reader)

### Monitored Messaging Apps
WhatsApp · WhatsApp Business · WeChat · Telegram · Messenger · Snapchat · Instagram · Signal · Session · Discord · Slack · Microsoft Teams · Viber · LINE · Kik

---

## iOS Setup Guide

### Prerequisites
- Xcode 15.0 or newer (macOS 13.5+)
- iOS 16.0+ on the child's iPhone
- Apple Developer account (paid, $99/year)
- **`com.apple.developer.family-controls` entitlement from Apple** — request at [developer.apple.com/contact/request/family-controls-distribution](https://developer.apple.com/contact/request/family-controls-distribution). Without this, FamilyControls APIs will not work.

### 1. Firebase Project (same as Android or shared)
1. In your Firebase project, add an iOS app with bundle ID `com.parentguard.monitor`
2. Download `GoogleService-Info.plist`
3. Add it to **both** the main app target AND the DeviceActivityExtension target in Xcode

### 2. Xcode Project Setup
```bash
cd ParentGuard-iOS
open ParentGuard.xcodeproj   # or create a new project and add the Swift files
```

In Xcode:

1. **Add Swift Package dependencies** (File → Add Package Dependencies):
   - `https://github.com/firebase/firebase-ios-sdk` — select FirebaseAuth, FirebaseFirestore, FirebaseMessaging

2. **Create the DeviceActivityExtension target** (File → New → Target → Device Activity Monitor Extension):
   - Name: `DeviceActivityExtension`
   - Add `MonitorExtension.swift` from `DeviceActivityExtension/`
   - Add `GoogleService-Info.plist` to this target
   - Add FirebaseFirestore + FirebaseAuth packages to this target

3. **App Groups** (Signing & Capabilities → + Capability → App Groups for BOTH targets):
   - `group.com.parentguard.monitor`

4. **Entitlements** (Signing & Capabilities → + Capability for main target):
   - `Family Controls` (requires Apple approval — see Prerequisites)

5. **Info.plist** — ensure `BGTaskSchedulerPermittedIdentifiers` contains:
   - `com.parentguard.monitor.sync`
   - `com.parentguard.monitor.longsync`
   - And `UIBackgroundModes` contains `fetch`, `processing`, `remote-notification`

### 3. Build and Install
```bash
# Build for a connected device (simulator doesn't support FamilyControls)
xcodebuild -scheme ParentGuard \
           -destination 'platform=iOS,name=Emma iPhone' \
           -configuration Debug \
           build
```
Or press ⌘R in Xcode with the child's iPhone connected.

### 4. Setup on Child's iPhone (parent-run)
The setup wizard guides through:
1. Enter Family Code (parent's Firebase UID from the parent dashboard)
2. Enter child's name
3. Grant Screen Time access (FamilyControls system prompt — tap **Allow**)
4. Allow notifications

---

## Permissions Reference

### Android
| Permission | Purpose |
|---|---|
| `READ_SMS` / `RECEIVE_SMS` | Read and intercept text messages |
| `READ_CALL_LOG` | Access call history |
| `READ_CONTACTS` | Resolve numbers to contact names |
| `PACKAGE_USAGE_STATS` | Read per-app screen time |
| `POST_NOTIFICATIONS` (API 33+) | Show foreground notification |
| `FOREGROUND_SERVICE` | Persistent monitoring service |
| `FOREGROUND_SERVICE_DATA_SYNC` | Required sub-type for API 34+ |
| `RECEIVE_BOOT_COMPLETED` | Restart after reboot |
| `INTERNET` / `ACCESS_NETWORK_STATE` | Upload to Firebase |
| `BIND_NOTIFICATION_LISTENER_SERVICE` | Read 3rd-party app notifications |
| `BIND_ACCESSIBILITY_SERVICE` (×2) | App blocking + sent message reading |

### iOS
| Permission / Framework | Purpose |
|---|---|
| FamilyControls (entitlement) | Monitor and restrict app usage |
| DeviceActivityMonitor (extension) | Usage callbacks in separate process |
| ManagedSettings | Apply restrictions (block apps, web) |
| BGAppRefreshTask | Periodic short background syncs |
| BGProcessingTask | Longer background data uploads |
| UNUserNotificationCenter | Send usage warnings and parent alerts |
| Push notifications | Silent push to trigger background fetch |

---

## Technical Reference

### Android
| Property | Value |
|---|---|
| Min SDK | API 26 (Android 8.0) |
| Target SDK | API 34 (Android 14) |
| Language | Kotlin 1.9 |
| Background layer 1 | Foreground service (continuous) |
| Background layer 2 | WorkManager (15-min periodic) |
| Background layer 3 | BroadcastReceiver (real-time SMS) |
| Firestore batch size | 400 ops (hard limit: 500) |
| Initial sync lookback | 30 days |

### iOS
| Property | Value |
|---|---|
| Min iOS | 16.0 |
| Language | Swift 5.9, SwiftUI |
| Background layer 1 | BGAppRefreshTask (~15–30 min) |
| Background layer 2 | BGProcessingTask (idle/charging) |
| Background layer 3 | DeviceActivityMonitorExtension (always-on, separate process) |
| Background layer 4 | Silent push notifications |
| Shared state | App Group UserDefaults (`group.com.parentguard.monitor`) |
| Firestore batch size | 400 ops |

---

## Legal & Ethical Requirements

> **This app is for parents monitoring their own minor children's devices.**

- You must own or have legal guardian authority over the monitored device.
- **Monitoring must be disclosed.** Android maintains a persistent foreground notification. iOS shows a Screen Time access prompt that the child can see. Do not attempt to hide or suppress either.
- This app is **not** for monitoring spouses, partners, employees, or adults without their explicit consent. Such use may violate wiretapping, electronic surveillance, or computer fraud laws.
- Laws vary by jurisdiction. Consult a legal professional if unsure.
- Have an open conversation with your child about what is monitored and why. Older teenagers have a reasonable expectation of privacy.

---

## Troubleshooting

### Android

**Monitoring stops after a few hours.**  
Aggressive battery optimizer is killing the foreground service. Set ParentGuard to "Don't optimise" in Settings → Battery → Battery optimisation. WorkManager will still sync every 15 minutes as a backstop even if the service is killed.

**App messages aren't captured.**  
Check Notification Access: Settings → Apps → Special app access → Notification access → ParentGuard must be on. Then confirm both Accessibility Services are enabled (App Monitor + Message Reader).

**Signal/Snapchat messages show `[Content hidden]`.**  
Open Signal → Settings → Notifications → Show → "Name and message". For Snapchat, enable notification previews in Android system notification settings.

### iOS

**FamilyControls authorization fails.**  
You need the `com.apple.developer.family-controls` entitlement. Request it at [developer.apple.com/contact/request/family-controls-distribution](https://developer.apple.com/contact/request/family-controls-distribution). Without it, the system prompt will not appear.

**BGTasks don't seem to run.**  
iOS throttles BGTasks heavily. In Xcode you can force a BGAppRefreshTask to fire for testing: pause the app in the debugger and run `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.parentguard.monitor.sync"]`. In production, tasks will fire on their own schedule.

**The DeviceActivityExtension doesn't seem to block apps.**  
Verify: (1) the App Group is added to both targets, (2) GoogleService-Info.plist is in the extension target, (3) the FamilyControls entitlement is in both targets' entitlements files, (4) `startMonitoring()` was called with the correct `DeviceActivityName`.

**Usage data shows app categories but not specific app names.**  
This is expected. Apple's privacy design makes app tokens opaque to third-party apps — you can block them (via FamilyActivityPicker selection) but you cannot programmatically read bundle IDs from tokens. The DeviceActivityReport view renders usage details using Apple's own UI.
