package com.parentguard.monitor

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log
import com.google.firebase.Timestamp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * SmsReceiver intercepts incoming SMS messages in real-time and uploads them immediately.
 * This supplements the polling approach in MonitoringService.
 */
class SmsReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (messages.isNullOrEmpty()) return

        val repository = FirebaseRepository()
        val collectors = DataCollectors(context)

        val records = messages.map { msg ->
            SmsRecord(
                id = "${msg.originatingAddress}_${msg.timestampMillis}",
                address = msg.originatingAddress ?: "Unknown",
                body = msg.messageBody ?: "",
                type = "INBOX",
                timestamp = Timestamp(java.util.Date(msg.timestampMillis))
            )
        }

        // Upload immediately on IO dispatcher
        CoroutineScope(Dispatchers.IO).launch {
            try {
                repository.uploadSmsRecords(records)
                Log.d(TAG, "Real-time SMS upload: ${records.size} messages")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to upload real-time SMS", e)
            }
        }
    }

    companion object {
        private const val TAG = "SmsReceiver"
    }
}

/**
 * BootReceiver restarts the monitoring service after device reboot.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            // Start the foreground service
            val serviceIntent = Intent(context, MonitoringService::class.java)
            context.startForegroundService(serviceIntent)

            // Also (re-)schedule WorkManager as a battery-optimizer-resistant backstop
            SyncWorker.schedulePeriodicSync(context)

            Log.d("BootReceiver", "MonitoringService restarted + WorkManager scheduled after boot")
        }
    }
}
