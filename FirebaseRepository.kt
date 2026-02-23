package com.parentguard.monitor

import android.util.Log
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import kotlinx.coroutines.tasks.await

/**
 * FirebaseRepository handles all Firestore read/write operations.
 *
 * Firestore structure:
 *   families/{familyId}/
 *     children/{childDeviceId}/
 *       profile        (DeviceProfile doc)
 *       sms/           (collection)
 *       calls/         (collection)
 *       appUsage/      (collection, one doc per date per app)
 *       blockedApps/   (collection)
 *       screenTimeLimits (doc)
 */
class FirebaseRepository {

    private val db   = FirebaseFirestore.getInstance()
    private val auth = FirebaseAuth.getInstance()

    private val prefs = AppPreferences.instance

    private val familyId: String get() = prefs.familyId
    private val childId:  String get() = prefs.childId

    /**
     * Security guard: every write path calls this first.
     * If the device has no authenticated Firebase user, writes are rejected locally —
     * Firestore security rules would reject them anyway, but failing fast avoids
     * wasting network and gives a clear log entry.
     */
    private fun requireAuth() {
        checkNotNull(auth.currentUser) {
            "FirebaseRepository: write attempted without an authenticated user — aborting"
        }
        require(familyId.isNotBlank()) { "familyId must not be blank" }
        require(childId.isNotBlank())  { "childId must not be blank" }
    }

    private fun childRef() = db
        .collection("families").document(familyId)
        .collection("children").document(childId)

    // ─── Batch helper ────────────────────────────────────────────────────────

    /**
     * Firestore batches are limited to 500 operations.
     * FIX: uploadSmsRecords / uploadCallRecords / uploadAppUsage previously created
     * a single batch over the entire list — crashing silently on first sync when
     * all historical records are fetched at once (potentially thousands of rows).
     * Now every upload function chunks into 400-item batches (safe margin below 500).
     */
    private suspend fun <T> batchWrite(
        items: List<T>,
        docRef: (T) -> com.google.firebase.firestore.DocumentReference,
        toMap: (T) -> Any = { it as Any }
    ) {
        items.chunked(400).forEach { chunk ->
            val batch = db.batch()
            chunk.forEach { item ->
                batch.set(docRef(item), toMap(item), SetOptions.merge())
            }
            batch.commit().await()
        }
    }

    // ─── Upload ──────────────────────────────────────────────────────────────

    suspend fun uploadSmsRecords(records: List<SmsRecord>) {
        if (records.isEmpty()) return
        requireAuth()
        batchWrite(records, { childRef().collection("sms").document(it.id) })
        Log.d(TAG, "Uploaded ${records.size} SMS records")
    }

    suspend fun uploadCallRecords(records: List<CallRecord>) {
        if (records.isEmpty()) return
        requireAuth()
        batchWrite(records, { childRef().collection("calls").document(it.id) })
        Log.d(TAG, "Uploaded ${records.size} call records")
    }

    suspend fun uploadAppUsage(records: List<AppUsageRecord>) {
        if (records.isEmpty()) return
        requireAuth()
        batchWrite(records, {
            val docId = "${it.date}_${it.packageName.replace(".", "_")}"
            childRef().collection("appUsage").document(docId)
        })
        Log.d(TAG, "Uploaded ${records.size} app usage records")
    }

    suspend fun updateDeviceProfile(profile: DeviceProfile) {
        requireAuth()
        childRef().collection("profile").document("info")
            .set(profile, SetOptions.merge()).await()
    }

    // ─── Download (parent commands) ──────────────────────────────────────────

    suspend fun getBlockedApps(): List<BlockedApp> {
        return try {
            val snapshot = childRef().collection("blockedApps").get().await()
            snapshot.toObjects(BlockedApp::class.java)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get blocked apps", e)
            emptyList()
        }
    }

    suspend fun getScreenTimeLimits(): ScreenTimeLimit {
        return try {
            val doc = childRef().document("screenTimeLimits").get().await()
            doc.toObject(ScreenTimeLimit::class.java) ?: ScreenTimeLimit()
        } catch (e: Exception) {
            ScreenTimeLimit()
        }
    }

    // ─── App Messages (WhatsApp, Telegram, Discord, etc.) ────────────────────

    suspend fun uploadAppMessages(messages: List<AppMessage>) {
        if (messages.isEmpty()) return
        requireAuth()
        batchWrite(messages, { childRef().collection("appMessages").document(it.id) })
        Log.d(TAG, "Uploaded ${messages.size} app messages")
    }

    // ─── Real-time listener for parent commands ───────────────────────────────

    fun listenForCommands(onBlockedAppsChanged: (List<BlockedApp>) -> Unit) {
        childRef().collection("blockedApps")
            .addSnapshotListener { snapshot, error ->
                if (error != null || snapshot == null) return@addSnapshotListener
                val apps = snapshot.toObjects(BlockedApp::class.java)
                onBlockedAppsChanged(apps)
            }
    }

    companion object {
        private const val TAG = "FirebaseRepository"
    }
}
