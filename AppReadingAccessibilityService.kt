package com.parentguard.monitor

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.google.firebase.Timestamp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * AppReadingAccessibilityService reads message content when the child is INSIDE
 * a messaging app. This captures SENT messages and message history visible on screen —
 * data that notification listeners cannot see.
 *
 * Strategy per app:
 * ─────────────────
 * WhatsApp / Messenger / Instagram DMs:
 *   Message bubbles are ViewGroups in a RecyclerView. We walk the view tree looking
 *   for TextView nodes containing message text and "outgoing" sibling indicators.
 *
 * Telegram:
 *   Uses a custom canvas-drawn UI — limited standard view tree. We rely on
 *   notification listener for incoming + check clipboard for outgoing.
 *
 * Discord / Slack / Teams:
 *   Standard WebView or native views; walk tree for message text nodes.
 *
 * NOTE: This service runs in addition to MessagingNotificationListener.
 * They complement each other:
 *   NotificationListener  → incoming messages (reliable, real-time)
 *   AccessibilityReader   → sent messages + on-screen chat history
 *
 * Android requires the user to explicitly grant Accessibility Service permission,
 * which the SetupActivity guides the parent through.
 */
class AppReadingAccessibilityService : AccessibilityService() {

    // FIX: Bind coroutine scope to service lifecycle via SupervisorJob.
    // Previously scope was unbound — uploads would continue running after the
    // service was destroyed. job.cancel() in onDestroy() stops them cleanly.
    private val job   = SupervisorJob()
    private val scope = CoroutineScope(Dispatchers.IO + job)
    private val repository by lazy { FirebaseRepository() }

    // FIX: Previously used text.hashCode() as a dedup key. Hash collisions (two
    // different messages sharing the same 32-bit hash) would silently drop real messages.
    // Now keyed by "${packageName}::${text}" — unique for any distinct (app, body) pair.
    // Capped at MAX_CACHE_SIZE via a simple LRU LinkedHashMap.
    private val lastSeenMessages: LinkedHashMap<String, Unit> = object :
        LinkedHashMap<String, Unit>(256, 0.75f, true) {
        override fun removeEldestEntry(eldest: Map.Entry<String, Unit>) = size > MAX_CACHE_SIZE
    }

    // Current foreground app
    private var currentPackage: String = ""

    companion object {
        private const val TAG = "AppReaderService"
        private const val MAX_TEXT_LENGTH = 2000
        private const val MAX_CACHE_SIZE  = 500  // max dedup entries before LRU eviction

        // View content descriptions / resource IDs used by each app to mark outgoing messages
        // These are heuristics based on known view hierarchies (may change with app updates)
        private val OUTGOING_INDICATORS = mapOf(
            "com.whatsapp" to listOf("sent", "message-text", "outgoing"),
            "com.facebook.orca" to listOf("sent", "outgoing_message"),
            "com.instagram.android" to listOf("direct_thread_outgoing"),
            "com.discord" to listOf("sent-message", "outgoing"),
            "com.Slack" to listOf("message", "sent"),
        )
    }

    override fun onServiceConnected() {
        serviceInfo = AccessibilityServiceInfo().apply {
            // Listen to window changes + content changes in target apps
            eventTypes = (AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
                    or AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED
                    or AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED)

            feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC

            packageNames = MessagingApps.ALL
                .map { it.packageName }
                .toTypedArray()

            notificationTimeout = 500
            flags = AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                    AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
        }
        Log.d(TAG, "AppReadingAccessibilityService connected, monitoring ${MessagingApps.ALL.size} apps")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event ?: return
        val pkg = event.packageName?.toString() ?: return
        val appInfo = MessagingApps.getByPackage(pkg) ?: return

        currentPackage = pkg

        when (event.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED -> {
                // Small delay to let UI settle before reading
                rootInActiveWindow?.let { rootNode ->
                    scanWindowForMessages(rootNode, appInfo)
                    rootNode.recycle()
                }
            }
        }
    }

    // ── Window Scanner ────────────────────────────────────────────────────────

    private fun scanWindowForMessages(root: AccessibilityNodeInfo, appInfo: MessagingAppInfo) {
        val messages = mutableListOf<AppMessage>()

        try {
            collectTextNodes(root, appInfo, messages, depth = 0)
        } catch (e: Exception) {
            Log.w(TAG, "Error scanning ${appInfo.displayName} window: ${e.message}")
        }

        if (messages.isEmpty()) return

        scope.launch {
            try {
                repository.uploadAppMessages(messages)
            } catch (e: Exception) {
                Log.e(TAG, "Upload failed", e)
            }
        }
    }

    /**
     * Depth-first tree walk collecting text nodes that look like chat messages.
     * We limit depth to avoid runaway traversal on complex layouts.
     */
    private fun collectTextNodes(
        node: AccessibilityNodeInfo,
        appInfo: MessagingAppInfo,
        output: MutableList<AppMessage>,
        depth: Int
    ) {
        if (depth > 12) return

        val text = node.text?.toString()?.trim() ?: ""

        if (text.isNotEmpty() && text.length > 2 && text.length < MAX_TEXT_LENGTH) {
            val isLikelyMessage = isMessageNode(node, appInfo)
            if (isLikelyMessage) {
                val direction = detectDirection(node, appInfo)
                // FIX: dedup key is now the full text (not hashCode), keyed by app package
                // to avoid cross-app collisions. LRU eviction prevents unbounded growth.
                val msgKey = "${appInfo.packageName}::${text}"

                if (!lastSeenMessages.containsKey(msgKey)) {
                    lastSeenMessages[msgKey] = Unit

                    output.add(
                        AppMessage(
                            id = UUID.randomUUID().toString(),
                            sourceApp = appInfo.displayName,
                            packageName = appInfo.packageName,
                            sender = if (direction == "SENT") AppPreferences.instance.childName else "Contact",
                            body = text,
                            contentVisible = true,
                            conversationId = "screen_${appInfo.packageName}",
                            direction = direction,
                            timestamp = Timestamp.now()
                        )
                    )
                }
            }
        }

        for (i in 0 until node.childCount) {
            node.getChild(i)?.let { child ->
                collectTextNodes(child, appInfo, output, depth + 1)
                child.recycle()
            }
        }
    }

    // ── Heuristics ────────────────────────────────────────────────────────────

    /**
     * Determines if a node is likely a chat message bubble (vs UI chrome).
     */
    private fun isMessageNode(node: AccessibilityNodeInfo, appInfo: MessagingAppInfo): Boolean {
        val cls = node.className?.toString() ?: ""
        val resId = node.viewIdResourceName ?: ""
        val desc = node.contentDescription?.toString() ?: ""

        // Filter out obvious non-message elements
        val nonMessageIds = listOf(
            "toolbar", "action_bar", "tab", "header", "title",
            "status_bar", "navigation", "search", "input", "compose",
            "send_button", "attach", "emoji", "mic"
        )
        if (nonMessageIds.any { resId.contains(it, ignoreCase = true) }) return false
        if (nonMessageIds.any { desc.contains(it, ignoreCase = true) }) return false

        // EditText nodes are the compose box — skip
        if (cls.contains("EditText")) return false

        // TextView with sufficient content suggests a message
        if (cls.contains("TextView") || cls.contains("Text")) return true

        return false
    }

    /**
     * Attempts to determine if this message was sent by the child or received.
     * Heuristic: look at the node's position/parent for outgoing indicators.
     */
    private fun detectDirection(node: AccessibilityNodeInfo, appInfo: MessagingAppInfo): String {
        val indicators = OUTGOING_INDICATORS[appInfo.packageName] ?: return "RECEIVED"
        val resId = node.viewIdResourceName ?: ""
        val parent = node.parent

        val parentResId = parent?.viewIdResourceName ?: ""
        val parentDesc = parent?.contentDescription?.toString() ?: ""
        parent?.recycle()

        val combined = "$resId $parentResId $parentDesc".lowercase()
        return if (indicators.any { combined.contains(it) }) "SENT" else "RECEIVED"
    }

    override fun onInterrupt() {
        Log.d(TAG, "AppReadingAccessibilityService interrupted")
    }

    override fun onDestroy() {
        super.onDestroy()
        job.cancel()
    }
}
