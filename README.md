# 🛡️ ParentGuard

**Transparent, consent-based parental monitoring for Android.**

ParentGuard lets parents monitor their child's SMS, calls, third-party app messages, and screen time from a web dashboard — with real-time app blocking and bedtime controls. Every component is designed to be disclosed: Android's foreground service requirement keeps a persistent notification on the child's device at all times, and the setup wizard is intended to be completed by a parent, with the child present.

---

## Table of Contents

1. [Features](#features)
2. [Architecture overview](#architecture-overview)
3. [Project structure](#project-structure)
4. [Prerequisites](#prerequisites)
5. [Setup guide](#setup-guide)
   - [Firebase project](#step-1-firebase-project)
   - [Firestore security rules](#step-2-firestore-security-rules)
   - [Build the Android app](#step-3-build-the-android-app)
   - [Install on child's device](#step-4-install-on-childs-device)
   - [Open the parent dashboard](#step-5-open-the-parent-dashboard)
6. [Monitored messaging apps](#monitored-messaging-apps)
7. [How message capture works](#how-message-capture-works)
8. [Parental controls](#parental-controls)
9. [Required permissions](#required-permissions)
10. [Security notes](#security-notes)
11. [Technical reference](#technical-reference)
12. [Legal & ethical requirements](#legal--ethical-requirements)
13. [Troubleshooting](#troubleshooting)

---

## Features

### Monitoring
| Capability | How |
|---|---|
| SMS messages | Android SMS content provider — sender, body, direction, timestamp |
| Call log | Android CallLog provider — number, contact name, duration, type |
| App messages | NotificationListenerService (incoming) + AccessibilityService (sent) |
| Screen time | UsageStatsManager — per-app time on screen, updated hourly |
| Device status | Online/offline state, battery level, last sync time |

### Messaging apps monitored
WhatsApp · WeChat · Telegram · Messenger · Snapchat · Instagram DMs · Signal · Session · Discord · Slack · Microsoft Teams *(plus WhatsApp Business, Viber, LINE, Kik)*

### Parental controls
| Control | Details |
|---|---|
| App blocking | Block any app all-day or on a time schedule (e.g. TikTok after 9 PM) |
| Screen time limit | Set a daily minute cap; device locks when reached |
| Bedtime mode | Phone locks at a set time each night and unlocks in the morning |

### Parent dashboard
- Per-app message filter pills with live counts
- Conversation thread view for any contact on any platform
- Flagged content indicators for privacy-redacted messages (Signal, Snapchat)
- Real-time alert feed (blocked app attempts, screen time warnings, battery)
- App usage bar chart with today's totals

---

## Architecture Overview

```
┌─────────────────────────────┐       ┌──────────────────────────────┐
│      Child's Android        │       │       Parent's Browser        │
│                             │       │                              │
│  ┌─────────────────────┐   │       │   parent-dashboard.html      │
│  │  MonitoringService  │   │       │   (connects to Firestore)    │
│  │  (foreground, 15m)  │   │       └──────────────┬───────────────┘
│  └────────┬────────────┘   │                      │
│           │                │       ┌──────────────▼───────────────┐
│  ┌────────▼────────────┐   │       │         Firebase             │
│  │   DataCollectors    │   │       │                              │
│  │  SMS · Calls · Apps │──────────▶  Firestore (families/{id}/   │
│  └─────────────────────┘   │       │    children/{id}/...)        │
│                             │       │                              │
│  ┌─────────────────────┐   │       │  Auth (parent & child UIDs)  │
│  │ MessagingNotification│──────────▶                              │
│  │ Listener (incoming) │   │       └──────────────────────────────┘
│  └─────────────────────┘   │
│                             │
│  ┌─────────────────────┐   │
│  │  AppReadingA11y     │   │
│  │  Service (sent msgs)│   │
│  └─────────────────────┘   │
│                             │
│  ┌─────────────────────┐   │
│  │ AppBlockerA11y      │   │
│  │ Service (blocking)  │   │
│  └─────────────────────┘   │
└─────────────────────────────┘
```

Data flows one way: child device → Firestore → parent dashboard. The parent dashboard writes only to `blockedApps` and `screenTimeLimits`; the child device reads those collections to enforce controls.

---

## Project Structure

```
ParentGuard/
├── app/
│   ├── build.gradle
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── java/com/parentguard/monitor/
│       │   ├── DataModels.kt                    — All data classes + MessagingApps registry
│       │   ├── AppPreferences.kt                — SharedPreferences wrapper (singleton)
│       │   ├── DataCollectors.kt                — Reads SMS, call log, UsageStats
│       │   ├── FirebaseRepository.kt            — All Firestore read/write (chunked batches)
│       │   ├── MonitoringService.kt             — Foreground service; drives 15-min sync loop
│       │   ├── MessagingNotificationListener.kt — NotificationListenerService for 11+ apps
│       │   ├── AppReadingAccessibilityService.kt— Reads sent messages from open app screens
│       │   ├── AppBlockerAccessibilityService.kt— Intercepts and blocks restricted apps
│       │   ├── Receivers.kt                     — SmsReceiver (real-time) + BootReceiver
│       │   ├── SetupActivity.kt                 — 4-step setup wizard (parent-run)
│       │   └── AppBlockedActivity.kt            — Full-screen block overlay for child
│       └── res/
│           ├── layout/
│           │   ├── activity_setup.xml
│           │   └── activity_app_blocked.xml
│           ├── values/
│           │   ├── strings.xml
│           │   └── themes.xml
│           └── xml/
│               ├── accessibility_service_config.xml   — App blocker config
│               └── accessibility_reader_config.xml    — Message reader config
├── parent-dashboard.html                        — Parent monitoring web UI
├── build.gradle
└── README.md
```

---

## Prerequisites

| Tool | Version |
|---|---|
| Android Studio | Hedgehog (2023.1.1) or newer |
| Android Gradle Plugin | 8.2.0+ |
| Kotlin | 1.9.21+ |
| Min Android on child's device | 8.0 (API 26) |
| Firebase account | Free Spark plan is sufficient |

---

## Setup Guide

### Step 1: Firebase Project

1. Go to [console.firebase.google.com](https://console.firebase.google.com) and create a new project named **ParentGuard**.
2. Under **Authentication → Sign-in method**, enable **Email/Password**.
3. Under **Firestore Database**, click **Create database** and choose **Production mode**.
4. Under **Project settings → Your apps**, click the Android icon. Register the app with package name `com.parentguard.monitor`, then download `google-services.json` and place it in the `app/` directory.

### Step 2: Firestore Security Rules

In the Firebase console under **Firestore → Rules**, replace the default rules with:

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    // Parent account reads all data for their family
    match /families/{familyId}/children/{childId}/{document=**} {
      allow read: if request.auth != null
                  && request.auth.uid == familyId;
    }

    // Child device writes only to its own sub-documents
    match /families/{familyId}/children/{childId}/sms/{doc} {
      allow write: if request.auth != null
                   && request.auth.uid == childId;
    }
    match /families/{familyId}/children/{childId}/calls/{doc} {
      allow write: if request.auth != null
                   && request.auth.uid == childId;
    }
    match /families/{familyId}/children/{childId}/appMessages/{doc} {
      allow write: if request.auth != null
                   && request.auth.uid == childId;
    }
    match /families/{familyId}/children/{childId}/appUsage/{doc} {
      allow write: if request.auth != null
                   && request.auth.uid == childId;
    }
    match /families/{familyId}/children/{childId}/profile/{doc} {
      allow write: if request.auth != null
                   && request.auth.uid == childId;
    }

    // Parent writes controls; child reads them
    match /families/{familyId}/children/{childId}/blockedApps/{doc} {
      allow read:  if request.auth != null
                   && request.auth.uid == childId;
      allow write: if request.auth != null
                   && request.auth.uid == familyId;
    }
    match /families/{familyId}/children/{childId}/screenTimeLimits/{doc} {
      allow read:  if request.auth != null
                   && request.auth.uid == childId;
      allow write: if request.auth != null
                   && request.auth.uid == familyId;
    }
  }
}
```

> **Why these rules matter:** without them, any authenticated user could read any family's data. The rules above ensure only the parent UID (`familyId`) can read monitoring data, and only the child UID (`childId`) can write to its own collections.

### Step 3: Build the Android App

```bash
# Clone or copy the project, then open in Android Studio
# Sync Gradle (it will download dependencies automatically)

# Build a debug APK
./gradlew assembleDebug

# Output: app/build/outputs/apk/debug/app-debug.apk
```

For a production release, use `assembleRelease` with a signing keystore configured in `build.gradle`.

### Step 4: Install on Child's Device

All of these steps should be performed by a parent.

1. On the child's device, go to **Settings → Security** and enable **Install unknown apps** for your file manager or browser.
2. Transfer `app-debug.apk` to the child's device (ADB, USB, or cloud storage) and install it.
3. Open **ParentGuard**. The setup wizard will guide you through four steps:

   | Step | What to do |
   |---|---|
   | **1 — Link family** | Enter the Family Code (your Firebase UID from the parent dashboard) and the child's name |
   | **2 — Runtime permissions** | Grant SMS, Call Log, Contacts, and Notifications when prompted |
   | **3 — Usage Access** | In the system settings screen that opens, find ParentGuard and enable it |
   | **4 — Notification Access** | In the system settings screen, enable **ParentGuard Notification Monitor** — this is required for WhatsApp, Telegram, Discord, and all other third-party messaging apps |
   | **5 — Accessibility Services** | Enable **both** ParentGuard services: *App Monitor* (blocking) and *Message Reader* (sent messages) |

4. After all steps complete, `SetupActivity` starts `MonitoringService` and exits. The child will see a persistent notification reading "ParentGuard Active — Device monitoring is on."

> **Note:** Android 13+ (API 33) requires a runtime `POST_NOTIFICATIONS` permission grant before the foreground notification can be shown. The setup wizard requests this automatically.

### Step 5: Open the Parent Dashboard

Open `parent-dashboard.html` in any modern browser for the monitoring interface.

**For production:** host it on Firebase Hosting (`firebase deploy --only hosting`) and wire it up to your Firestore project using the Firebase JS SDK. The dashboard currently uses static demo data; replace the `APP_MSGS`, `SMS_DATA`, `CALLS_DATA`, and `USAGE_DATA` arrays with live Firestore queries.

---

## Monitored Messaging Apps

| App | Package | Incoming msgs | Sent msgs | Privacy mode |
|---|---|---|---|---|
| WhatsApp | `com.whatsapp` | ✅ Notification | ✅ Accessibility | — |
| WhatsApp Business | `com.whatsapp.w4b` | ✅ Notification | ✅ Accessibility | — |
| WeChat | `com.tencent.mm` | ✅ Notification | ✅ Accessibility | — |
| Telegram | `org.telegram.messenger` | ✅ Notification | ⚠️ Partial (canvas UI) | — |
| Messenger | `com.facebook.orca` | ✅ Notification | ✅ Accessibility | — |
| Snapchat | `com.snapchat.android` | ✅ Notification | ✅ Accessibility | 🔒 Hides content by default |
| Instagram | `com.instagram.android` | ✅ Notification | ✅ Accessibility | — |
| Signal | `org.thoughtcrime.securesms` | ✅ Notification | ✅ Accessibility | 🔒 Hides content when privacy mode on |
| Session | `network.loki.messenger` | ✅ Notification | ✅ Accessibility | 🔒 May hide content |
| Discord | `com.discord` | ✅ Notification | ✅ Accessibility | — |
| Slack | `com.Slack` | ✅ Notification | ✅ Accessibility | — |
| Microsoft Teams | `com.microsoft.teams` | ✅ Notification | ✅ Accessibility | — |

**Privacy mode** means the app posts notifications without message text (e.g. "New message"). The dashboard marks these as `[Content hidden by App]`. To see content, open the messaging app's notification settings on the child's device and set previews to **Show**.

---

## How Message Capture Works

Two Android services work together to capture the full conversation:

### Incoming messages — `MessagingNotificationListener`

Extends `NotificationListenerService`. Android delivers a copy of every notification to this service after the user grants Notification Access. For each notification from a monitored package, it extracts:

- **MessagingStyle notifications** (WhatsApp, Telegram, Messenger): rich per-message bundles with individual sender names and timestamps.
- **Standard / BigText notifications** (Discord, Slack, Teams): title as sender, body as text.
- **Grouped notifications**: skips the group-summary notification and processes only the individual message notifications to avoid duplicates.

A `LinkedHashMap`-based dedup window (10 seconds) prevents re-uploading the same notification if the app updates it.

### Sent messages — `AppReadingAccessibilityService`

Extends `AccessibilityService`. When the child opens a messaging app, this service receives `TYPE_WINDOW_CONTENT_CHANGED` events and walks the view tree looking for `TextView` nodes that match message bubble heuristics — filtering out compose boxes, toolbars, and navigation elements. Detected direction (SENT vs RECEIVED) is determined by matching known outgoing-bubble resource IDs per app.

Limitations:
- Telegram uses a canvas-drawn UI with minimal view-tree content. Sent messages in Telegram are captured only partially.
- View IDs are heuristics and may break on major app updates. Incoming-only capture via the notification listener is unaffected by this.

---

## Parental Controls

### App Blocking

Parents add apps to the block list from the dashboard. The list is synced to Firestore and pushed to the child's device via a real-time snapshot listener in `MonitoringService`. When the child opens a blocked app, `AppBlockerAccessibilityService` detects the `TYPE_WINDOW_STATE_CHANGED` event, navigates to the home screen, and launches `AppBlockedActivity` — a full-screen overlay the child cannot dismiss.

Blocking can be configured:
- **All day** — app is blocked at all times
- **Scheduled** — app is blocked between two times (supports ranges crossing midnight, e.g. 10 PM – 7 AM)

### Screen Time

A daily minute limit is stored in Firestore under `screenTimeLimits`. `MonitoringService` compares actual usage (from `UsageStatsManager`) to the limit on each hourly sync. When the limit is reached, `AppBlockerAccessibilityService` begins blocking all apps except the phone dialler and this app itself.

### Bedtime Mode

A start and end time are stored in `screenTimeLimits`. `AppBlockerAccessibilityService` checks the current time against the bedtime window on every foreground-app-change event and blocks all apps during that window.

---

## Required Permissions

| Permission | Type | Purpose |
|---|---|---|
| `READ_SMS` | Runtime | Read existing SMS threads |
| `RECEIVE_SMS` | Runtime | Intercept incoming SMS in real time |
| `READ_CALL_LOG` | Runtime | Access call history |
| `READ_CONTACTS` | Runtime | Resolve numbers to contact names |
| `POST_NOTIFICATIONS` | Runtime (API 33+) | Show the foreground monitoring notification |
| `PACKAGE_USAGE_STATS` | Special (system settings) | Read per-app screen time via UsageStatsManager |
| `FOREGROUND_SERVICE` | Normal | Declare the monitoring service as foreground |
| `FOREGROUND_SERVICE_DATA_SYNC` | Normal | Required sub-type for API 34+ foreground services |
| `RECEIVE_BOOT_COMPLETED` | Normal | Restart monitoring service after reboot |
| `INTERNET` | Normal | Upload data to Firebase |
| `ACCESS_NETWORK_STATE` | Normal | Check connectivity before upload attempts |
| `BIND_NOTIFICATION_LISTENER_SERVICE` | Special (system settings) | Read notifications from third-party messaging apps |
| `BIND_ACCESSIBILITY_SERVICE` | Special (system settings) | App blocking + sent message reading |

---

## Security Notes

### Authentication and data isolation

- Every Firestore write is guarded by `FirebaseRepository.requireAuth()`, which throws immediately if `FirebaseAuth.currentUser` is null, `familyId` is blank, or `childId` is blank — before any network call is made.
- Firestore security rules (see Step 2) enforce that a child UID can only write to its own path, and only the parent UID can read monitoring data.
- No two families can access each other's data regardless of client-side state.

### Batch write safety

Firestore enforces a hard limit of 500 operations per batch. All upload functions use a shared `batchWrite()` helper that chunks records into groups of 400. Additionally, `DataCollectors` caps the initial sync lookback to the most recent 30 days, preventing a first-run batch that could contain years of SMS and call history.

### Dashboard XSS protection

All user-controlled strings rendered into `innerHTML` (contact names, message bodies, phone numbers, app names entered by the parent) are passed through `escHtml()`, which escapes `& < > " '`. Interactive elements use `data-*` attributes and a central event delegation handler — no inline `onclick` attributes with interpolated data exist anywhere in the rendered HTML. A `Content-Security-Policy` meta tag restricts script and style sources.

### Coroutine lifecycle

Both `MessagingNotificationListener` and `AppReadingAccessibilityService` use a `SupervisorJob` bound to their `onDestroy()` lifecycle. The job is cancelled on destroy, stopping any in-flight Firebase uploads and preventing memory or thread leaks after the service is unbound.

### Message deduplication

`MessagingNotificationListener` uses a time-windowed `LinkedHashMap` keyed on the notification's composite key to prevent double-uploading when apps refresh their notifications. `AppReadingAccessibilityService` uses a full-text LRU `LinkedHashMap` (capped at 500 entries) keyed on `packageName::messageText` — replacing the previous `hashCode()`-based approach, which was susceptible to hash collisions silently dropping real messages.

---

## Technical Reference

| Property | Value |
|---|---|
| Min SDK | API 26 (Android 8.0 Oreo) |
| Target SDK | API 34 (Android 14) |
| Language | Kotlin 1.9 |
| Build system | Gradle 8.2 / AGP 8.2.0 |
| Backend | Firebase Firestore + Firebase Auth |
| SMS/Call sync interval | Every 15 minutes |
| App usage sync interval | Every 1 hour |
| Real-time SMS capture | Immediate (BroadcastReceiver) |
| Real-time app message capture | Immediate (NotificationListenerService) |
| Initial sync lookback cap | 30 days |
| Firestore batch size | 400 operations (hard limit is 500) |
| Message dedup window | 10 seconds (notification listener) |
| Accessibility dedup cache | 500 entries LRU (screen reader) |

### Firestore data structure

```
families/
  {parentUid}/                        ← familyId = parent's Firebase UID
    children/
      {childUid}/                     ← childId = child device's Firebase UID
        profile/
          info                        ← DeviceProfile document
        sms/
          {smsId}                     ← SmsRecord documents
        calls/
          {callId}                    ← CallRecord documents
        appUsage/
          {date}_{packageName}        ← AppUsageRecord documents
        appMessages/
          {uuid}                      ← AppMessage documents
        blockedApps/
          {packageName}               ← BlockedApp documents (parent writes, child reads)
        screenTimeLimits/
          limits                      ← ScreenTimeLimit document (parent writes, child reads)
```

---

## Legal & Ethical Requirements

> **This app is designed for parents monitoring their own minor children's devices.**

- You must **own or have legal guardian authority** over the device being monitored.
- **Monitoring must be disclosed.** Android's foreground service requirement ensures a persistent notification is always visible on the child's device. Do not attempt to hide or suppress this notification.
- This app is **not** intended for monitoring spouses, partners, employees, adults, or anyone who has not given informed consent. Using it for those purposes may be illegal under wiretapping, electronic surveillance, or computer fraud laws in your jurisdiction.
- Laws governing parental monitoring vary by country and, in the US, by state. Consult a legal professional if you are unsure about your obligations.
- Consider age-appropriate monitoring. Older teenagers have a reasonable expectation of privacy. Having an open conversation with your child about what is monitored and why is strongly recommended.

---

## Troubleshooting

**The monitoring notification disappears after a few minutes.**  
Battery optimisation is killing the foreground service. Go to **Settings → Battery → Battery optimisation** on the child's device, find ParentGuard, and set it to **Don't optimise**. On some manufacturers (Xiaomi, Huawei, OnePlus) there are additional auto-start and background task restrictions in the settings — enable ParentGuard in all of them.

**App messages aren't appearing in the dashboard.**  
Check that Notification Access is granted: **Settings → Apps & Notifications → Special app access → Notification access → ParentGuard Notification Monitor** should be toggled on. If it was recently granted, restart the child's device.

**Sent messages are missing but received ones appear.**  
Sent messages are captured by `AppReadingAccessibilityService`. Confirm both Accessibility Services are enabled in **Settings → Accessibility**. The *Message Reader* service is separate from the *App Monitor* service — both must be on.

**Signal / Snapchat messages show `[Content hidden]`.**  
Open the app on the child's device, go to its notification settings, and change the notification style to show message content (not just sender name or nothing). Signal: **Signal Settings → Notifications → Show → Name and message**. Snapchat: enable notification previews in Android system notification settings for Snapchat.

**Telegram sent messages are missing.**  
Telegram renders its chat UI on a custom canvas, which exposes minimal content to the accessibility view tree. Incoming Telegram messages (via notifications) are captured normally. Full sent-message capture for Telegram is a known limitation.

**The dashboard shows demo data and not live data.**  
The HTML dashboard currently ships with static demo data. To connect it to Firebase, add the Firebase JS SDK and replace the `APP_MSGS`, `SMS_DATA`, `CALLS_DATA`, and `USAGE_DATA` constants with live `onSnapshot()` queries against your Firestore collections.

**Build fails with `google-services.json not found`.**  
Download `google-services.json` from your Firebase project (**Project settings → Your apps → Android app → Download google-services.json**) and place it in the `app/` directory, not the project root.
