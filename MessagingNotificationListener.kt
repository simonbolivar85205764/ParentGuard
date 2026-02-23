package com.parentguard.monitor

import android.app.Notification
import android.content.pm.PackageManager
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import com.google.firebase.Timestamp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * MessagingNotificationListener monitors notifications from all configured
 * messaging apps and uploads captured messages to Firebase in real-time.
 *
 * HOW IT WORKS:
 * ─────────────
 * Android's NotificationListenerService gives access to every notification posted
 * system-wide (after the user grants permission in Settings → Notifications → 
 * Notification Access). We extract the sender (title) and message text (bigText or
 * text extra) from each notification that originates from a monitored app package.
 *
 * LIMITATIONS:
 * ─────────────
 * 1. Only RECEIVED messages appear as notifications; outgoing sent messages do not.
 *    (Outgoing WhatsApp/Telegram messages can only be captured with Accessibility
 *    Service screen reading, which is covered by AppReadingAccessibilityService.)
 *
 * 2. Apps that enable notification privacy (Signal "No name or message" mode,
 *    Snapchat default on some versions) will yield a placeholder body. The
 *    [AppMessage.contentVisible] flag will be false in those cases.
 *
 * 3. Group notifications may be posted as a summary with multiple messages bundled;
 *    we iterate through the notification group children to extract individual messages.
 */
class MessagingNotificationListener : NotificationListenerService() {

    // FIX: Use SupervisorJob so one failing coroutine doesn't cancel others.
    // The job is cancelled in onDestroy() to prevent coroutine leaks after the
    // service is unbound — previously the scope lived indefinitely.
    private val job   = SupervisorJob()
    private val scope = CoroutineScope(Dispatchers.IO + job)
    private val repository by lazy { FirebaseRepository() }

    // Deduplicate: track recently uploaded notification keys to avoid double-uploads
    // from grouped/updated notifications
    private val recentlyUploaded = LinkedHashMap<String, Long>(100, 0.75f, true)
    private val DEDUP_WINDOW_MS = 10_000L  // 10 seconds

    companion object {
        private const val TAG = "MsgNotifListener"

        // Apps that hide message body text in notifications
        private val PRIVACY_PACKAGES = setOf(
            "org.thoughtcrime.securesms",   // Signal (when set to hide)
            "network.loki.messenger",       // Session
            "com.snapchat.android"          // Snapchat
        )

        private val PRIVACY_BODY_MARKERS = setOf(
            "New message",
            "New Snap",
            "Signal message",
            "Session message",
            "You have a new message",
            "1 new message"
        )
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        sbn ?: return
        val pkg = sbn.packageName ?: return

        // Only process monitored messaging apps
        val appInfo = MessagingApps.getByPackage(pkg) ?: return

        // Skip our own app notifications
        if (pkg == this.packageName) return

        // Dedup check
        val notifKey = "${sbn.key}_${sbn.notification?.`when`}"
        val now = System.currentTimeMillis()
        synchronized(recentlyUploaded) {
            // Clean old entries
            recentlyUploaded.entries.removeAll { now - it.value > DEDUP_WINDOW_MS }
            if (recentlyUploaded.containsKey(notifKey)) return
            recentlyUploaded[notifKey] = now
        }

        // Extract message data from notification extras
        val messages = extractMessages(sbn, appInfo)

        if (messages.isEmpty()) return

        Log.d(TAG, "Captured ${messages.size} message(s) from ${appInfo.displayName}")

        scope.launch {
            try {
                repository.uploadAppMessages(messages)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to upload ${appInfo.displayName} messages", e)
            }
        }
    }

    // ── Message Extraction ────────────────────────────────────────────────────

    /**
     * Extracts one or more AppMessage objects from a StatusBarNotification.
     * Handles three notification styles:
     *  1. Standard (single message): title = sender, text = body
     *  2. MessagingStyle: bundles multiple messages with per-message sender info
     *  3. InboxStyle: multiple lines in a summary notification
     */
    private fun extractMessages(
        sbn: StatusBarNotification,
        appInfo: MessagingAppInfo
    ): List<AppMessage> {

        val notification = sbn.notification ?: return emptyList()
        val extras = notification.extras ?: return emptyList()

        // Skip group summary-only notifications (the individual ones carry the content)
        val isGroupSummary = (notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0
        if (isGroupSummary && extras.getParcelableArray(Notification.EXTRA_MESSAGES) == null) {
            return emptyList()
        }

        val timestamp = Timestamp(java.util.Date(sbn.notification.`when`.takeIf { it > 0 }
            ?: System.currentTimeMillis()))

        val conversationId = sbn.groupKey ?: sbn.tag ?: sbn.id.toString()

        // ── MessagingStyle (richest data) ────────────────────────────────────
        @Suppress("UNCHECKED_CAST")
        val messagingMessages = extras.getParcelableArray(Notification.EXTRA_MESSAGES)
        if (messagingMessages != null) {
            return messagingMessages.mapNotNull { msgBundle ->
                if (msgBundle !is Bundle) return@mapNotNull null
                val sender = msgBundle.getCharSequence("sender")?.toString()
                    ?: extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
                    ?: "Unknown"
                val text = msgBundle.getCharSequence("text")?.toString() ?: return@mapNotNull null
                val msgTime = msgBundle.getLong("time").let {
                    if (it > 0) Timestamp(java.util.Date(it)) else timestamp
                }
                buildMessage(appInfo, sbn, sender, text, msgTime, conversationId)
            }
        }

        // ── Standard / BigText style ──────────────────────────────────────────
        val title  = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
        val text   = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
        val body   = bigText ?: text

        if (title.isBlank() && body.isBlank()) return emptyList()

        // For group chat apps (Discord, Slack, Teams) the title may be "#channel | Server"
        // We keep it as-is for the parent to see context
        val sender = title.ifBlank { "Unknown" }

        return listOf(buildMessage(appInfo, sbn, sender, body, timestamp, conversationId))
    }

    private fun buildMessage(
        appInfo: MessagingAppInfo,
        sbn: StatusBarNotification,
        sender: String,
        body: String,
        timestamp: Timestamp,
        conversationId: String
    ): AppMessage {
        val isPrivacyRedacted = appInfo.packageName in PRIVACY_PACKAGES
            && (body.isBlank() || PRIVACY_BODY_MARKERS.any { body.contains(it, ignoreCase = true) })

        return AppMessage(
            id = UUID.randomUUID().toString(),
            sourceApp = appInfo.displayName,
            packageName = appInfo.packageName,
            sender = sender.trim(),
            body = if (isPrivacyRedacted) "[Content hidden by ${appInfo.displayName}]" else body.trim(),
            contentVisible = !isPrivacyRedacted,
            conversationId = conversationId,
            direction = "RECEIVED",
            timestamp = timestamp
        )
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        // No action needed — we store the message regardless of notification dismissal
    }

    override fun onListenerConnected() {
        Log.d(TAG, "MessagingNotificationListener connected")
    }

    override fun onListenerDisconnected() {
        Log.d(TAG, "MessagingNotificationListener disconnected")
    }

    override fun onDestroy() {
        super.onDestroy()
        job.cancel()
    }
}
