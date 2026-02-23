package com.parentguard.monitor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.util.Log
import kotlinx.coroutines.*
import java.util.concurrent.TimeUnit

/**
 * MonitoringService runs as a foreground service to continuously collect
 * and upload monitoring data to Firebase.
 *
 * Sync interval: every 15 minutes for SMS/calls, every hour for app usage.
 * The foreground notification is transparent to the child that monitoring
 * is active (required by Android for foreground services).
 */
class MonitoringService : Service() {

    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private lateinit var collectors: DataCollectors
    private lateinit var repository: FirebaseRepository

    companion object {
        private const val TAG = "MonitoringService"
        const val CHANNEL_ID = "parentguard_monitoring"
        const val NOTIFICATION_ID = 1001
        private val SYNC_INTERVAL_MS = TimeUnit.MINUTES.toMillis(15)
        private val APP_USAGE_INTERVAL_MS = TimeUnit.HOURS.toMillis(1)
    }

    override fun onCreate() {
        super.onCreate()
        collectors = DataCollectors(this)
        repository = FirebaseRepository()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(
            NOTIFICATION_ID,
            buildNotification(),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        )

        startSyncLoop()
        startAppUsageLoop()
        listenForParentCommands()

        // WorkManager as a backstop: if this foreground service is killed by an aggressive
        // battery optimizer, WorkManager will still fire SyncWorker every 15 minutes and
        // attempt to restart us.
        SyncWorker.schedulePeriodicSync(this)

        Log.d(TAG, "MonitoringService started")
        return START_STICKY // Restart if killed by system
    }

    // ─── Sync Loops ──────────────────────────────────────────────────────────

    private fun startSyncLoop() {
        serviceScope.launch {
            while (isActive) {
                syncSmsAndCalls()
                delay(SYNC_INTERVAL_MS)
            }
        }
    }

    private fun startAppUsageLoop() {
        serviceScope.launch {
            while (isActive) {
                syncAppUsage()
                delay(APP_USAGE_INTERVAL_MS)
            }
        }
    }

    private suspend fun syncSmsAndCalls() {
        try {
            val smsList = collectors.collectSms()
            if (smsList.isNotEmpty()) {
                repository.uploadSmsRecords(smsList)
            }

            val callList = collectors.collectCallLog()
            if (callList.isNotEmpty()) {
                repository.uploadCallRecords(callList)
            }

            repository.updateDeviceProfile(buildDeviceProfile())
        } catch (e: Exception) {
            Log.e(TAG, "SMS/Call sync failed", e)
        }
    }

    private suspend fun syncAppUsage() {
        try {
            val usageList = collectors.collectAppUsage()
            if (usageList.isNotEmpty()) {
                repository.uploadAppUsage(usageList)
            }
        } catch (e: Exception) {
            Log.e(TAG, "App usage sync failed", e)
        }
    }

    private fun listenForParentCommands() {
        repository.listenForCommands { blockedApps ->
            AppPreferences.instance.saveBlockedApps(blockedApps)
            Log.d(TAG, "Updated blocked apps: ${blockedApps.map { it.appName }}")
        }
    }

    // ─── Device Profile ──────────────────────────────────────────────────────

    private fun buildDeviceProfile(): DeviceProfile {
        val batteryManager = getSystemService(BATTERY_SERVICE)
        return DeviceProfile(
            childName = AppPreferences.instance.childName,
            deviceModel = android.os.Build.MODEL,
            androidVersion = android.os.Build.VERSION.RELEASE,
            isOnline = true
        )
    }

    // ─── Notification ────────────────────────────────────────────────────────

    private fun buildNotification(): Notification {
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("ParentGuard Active")
            .setContentText("Device monitoring is on")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .build()
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "ParentGuard Monitoring",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Keeps parental monitoring active"
            setShowBadge(false)
        }
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(channel)
    }

    override fun onDestroy() {
        super.onDestroy()
        serviceScope.cancel()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
