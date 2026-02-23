package com.parentguard.monitor

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * SyncWorker is a WorkManager [CoroutineWorker] that performs the same SMS, call log,
 * and app usage sync as [MonitoringService], but operates as a backstop when the foreground
 * service is killed by aggressive battery optimizers (common on Xiaomi, Huawei, OnePlus,
 * and Samsung in power-saving modes).
 *
 * WorkManager is managed by the Android OS job scheduler, which gives it stronger survival
 * guarantees than a plain service on many OEMs.  Even if our foreground service dies:
 *  1. WorkManager will fire this worker at the next 15-minute window
 *  2. The worker re-starts MonitoringService before uploading
 *  3. MonitoringService's START_STICKY ensures it self-restarts after system kills
 *
 * Scheduling:
 *   [schedulePeriodicSync] should be called at app start (SetupActivity) and after every boot
 *   (BootReceiver). WorkManager deduplicates: calling it repeatedly with the same uniqueWorkName
 *   and KEEP policy is safe.
 */
class SyncWorker(
    appContext: Context,
    params: WorkerParameters
) : CoroutineWorker(appContext, params) {

    private val collectors   = DataCollectors(appContext)
    private val repository   = FirebaseRepository()

    override suspend fun doWork(): Result {
        Log.d(TAG, "SyncWorker executing")

        // Always make sure the foreground service is running while we're here
        ensureServiceRunning()

        return try {
            syncSmsAndCalls()
            syncAppUsage()
            Log.d(TAG, "SyncWorker completed successfully")
            Result.success()
        } catch (e: Exception) {
            Log.e(TAG, "SyncWorker failed — will retry", e)
            // Retry up to 3 times with exponential back-off before giving up until next period
            if (runAttemptCount < 3) Result.retry() else Result.failure()
        }
    }

    // ── Sync operations ───────────────────────────────────────────────────────

    private suspend fun syncSmsAndCalls() {
        val smsList = collectors.collectSms()
        if (smsList.isNotEmpty()) repository.uploadSmsRecords(smsList)

        val callList = collectors.collectCallLog()
        if (callList.isNotEmpty()) repository.uploadCallRecords(callList)
    }

    private suspend fun syncAppUsage() {
        val usageList = collectors.collectAppUsage()
        if (usageList.isNotEmpty()) repository.uploadAppUsage(usageList)
    }

    private fun ensureServiceRunning() {
        try {
            val intent = android.content.Intent(applicationContext, MonitoringService::class.java)
            applicationContext.startForegroundService(intent)
        } catch (e: Exception) {
            // Foreground service start can fail in some background execution contexts;
            // that's acceptable — the worker will still do the upload
            Log.w(TAG, "Could not re-start MonitoringService from worker: ${e.message}")
        }
    }

    // ── Scheduling ────────────────────────────────────────────────────────────

    companion object {
        private const val TAG             = "SyncWorker"
        private const val WORK_NAME       = "parentguard_periodic_sync"
        private const val INTERVAL_MINS   = 15L

        /**
         * Enqueue (or keep existing) a periodic sync that fires at most every 15 minutes,
         * only when the device has a network connection.
         *
         * Call this from [SetupActivity] after setup completes and from [BootReceiver] on reboot.
         */
        fun schedulePeriodicSync(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            val request = PeriodicWorkRequestBuilder<SyncWorker>(
                INTERVAL_MINS, TimeUnit.MINUTES,
                // Flex window: run anytime in the last 5 minutes of each 15-min period
                5L, TimeUnit.MINUTES
            )
                .setConstraints(constraints)
                .build()

            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,  // don't reset the timer if already scheduled
                request
            )

            Log.d(TAG, "Periodic sync scheduled every $INTERVAL_MINS min via WorkManager")
        }

        /**
         * Cancel the periodic sync — call when the user unlinks the device.
         */
        fun cancelPeriodicSync(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
            Log.d(TAG, "Periodic sync cancelled")
        }
    }
}
