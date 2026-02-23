package com.parentguard.monitor

import android.app.usage.UsageStatsManager
import android.content.ContentResolver
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.provider.CallLog
import android.provider.ContactsContract
import android.provider.Telephony
import android.util.Log
import com.google.firebase.Timestamp
import java.text.SimpleDateFormat
import java.util.*

/**
 * DataCollectors reads monitoring data from the Android system.
 * All collection is transparent – data is only read after explicit
 * parental consent is granted during setup.
 */
class DataCollectors(private val context: Context) {

    private val contentResolver: ContentResolver = context.contentResolver
    private val packageManager: PackageManager   = context.packageManager
    private val prefs = AppPreferences.instance

    companion object {
        private const val TAG = "DataCollectors"
        // FIX: On first run lastSmsSync/lastCallSync are 0L, which means "fetch all time".
        // Capping the lookback to 30 days prevents a massive initial batch that would
        // exceed Firestore's 500-operation batch limit (and be costly/slow).
        private val MAX_LOOKBACK_MS = 30L * 24 * 60 * 60 * 1000   // 30 days
        private const val MAX_BODY_LENGTH = 4000  // chars; cap extremely long SMS/MMS
    }

    /** Returns the effective since-timestamp: whichever is more recent — stored value or 30-day cap. */
    private fun effectiveSince(storedTimestamp: Long): Long {
        val cap = System.currentTimeMillis() - MAX_LOOKBACK_MS
        return maxOf(storedTimestamp, cap)
    }

    // ─── SMS ─────────────────────────────────────────────────────────────────

    /**
     * Reads SMS messages since the last sync timestamp.
     */
    fun collectSms(sinceTimestamp: Long = prefs.lastSmsSync): List<SmsRecord> {
        val records = mutableListOf<SmsRecord>()
        val since = effectiveSince(sinceTimestamp)  // FIX: cap lookback to 30 days

        val projection = arrayOf(
            Telephony.Sms._ID,
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.TYPE,
            Telephony.Sms.DATE
        )
        val selection = "${Telephony.Sms.DATE} > ?"
        val selectionArgs = arrayOf(since.toString())

        try {
            val cursor: Cursor? = contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                projection,
                selection,
                selectionArgs,
                "${Telephony.Sms.DATE} DESC"
            )

            cursor?.use {
                while (it.moveToNext()) {
                    val id      = it.getString(it.getColumnIndexOrThrow(Telephony.Sms._ID))
                    val address = it.getString(it.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)) ?: "Unknown"
                    val body    = (it.getString(it.getColumnIndexOrThrow(Telephony.Sms.BODY)) ?: "")
                        .take(MAX_BODY_LENGTH)  // FIX: cap extremely long message bodies
                    val typeInt = it.getInt(it.getColumnIndexOrThrow(Telephony.Sms.TYPE))
                    val date    = it.getLong(it.getColumnIndexOrThrow(Telephony.Sms.DATE))

                    val typeStr = when (typeInt) {
                        Telephony.Sms.MESSAGE_TYPE_INBOX -> "INBOX"
                        Telephony.Sms.MESSAGE_TYPE_SENT  -> "SENT"
                        else -> "OTHER"
                    }

                    records.add(
                        SmsRecord(
                            id          = id,
                            address     = address,
                            body        = body,
                            type        = typeStr,
                            timestamp   = Timestamp(Date(date)),
                            contactName = lookupContactName(address)
                        )
                    )
                }
            }
        } catch (e: SecurityException) {
            Log.e(TAG, "SMS permission denied", e)
        } catch (e: Exception) {
            Log.e(TAG, "Error collecting SMS", e)
        }

        if (records.isNotEmpty()) prefs.lastSmsSync = System.currentTimeMillis()
        Log.d(TAG, "Collected ${records.size} SMS messages")
        return records
    }

    // ─── Call Log ────────────────────────────────────────────────────────────

    fun collectCallLog(sinceTimestamp: Long = prefs.lastCallSync): List<CallRecord> {
        val records = mutableListOf<CallRecord>()
        val since = effectiveSince(sinceTimestamp)  // FIX: cap lookback to 30 days

        val projection = arrayOf(
            CallLog.Calls._ID,
            CallLog.Calls.NUMBER,
            CallLog.Calls.CACHED_NAME,
            CallLog.Calls.TYPE,
            CallLog.Calls.DURATION,
            CallLog.Calls.DATE
        )
        val selection = "${CallLog.Calls.DATE} > ?"
        val selectionArgs = arrayOf(since.toString())

        try {
            val cursor: Cursor? = contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                projection,
                selection,
                selectionArgs,
                "${CallLog.Calls.DATE} DESC"
            )

            cursor?.use {
                while (it.moveToNext()) {
                    val id = it.getString(it.getColumnIndexOrThrow(CallLog.Calls._ID))
                    val number = it.getString(it.getColumnIndexOrThrow(CallLog.Calls.NUMBER)) ?: "Unknown"
                    val name = it.getString(it.getColumnIndexOrThrow(CallLog.Calls.CACHED_NAME)) ?: ""
                    val typeInt = it.getInt(it.getColumnIndexOrThrow(CallLog.Calls.TYPE))
                    val duration = it.getInt(it.getColumnIndexOrThrow(CallLog.Calls.DURATION))
                    val date = it.getLong(it.getColumnIndexOrThrow(CallLog.Calls.DATE))

                    val typeStr = when (typeInt) {
                        CallLog.Calls.INCOMING_TYPE -> "INCOMING"
                        CallLog.Calls.OUTGOING_TYPE -> "OUTGOING"
                        CallLog.Calls.MISSED_TYPE -> "MISSED"
                        CallLog.Calls.REJECTED_TYPE -> "REJECTED"
                        else -> "UNKNOWN"
                    }

                    records.add(
                        CallRecord(
                            id = id,
                            number = number,
                            contactName = name.ifEmpty { lookupContactName(number) },
                            type = typeStr,
                            durationSeconds = duration,
                            timestamp = Timestamp(Date(date))
                        )
                    )
                }
            }
        } catch (e: SecurityException) {
            Log.e(TAG, "Call log permission denied", e)
        } catch (e: Exception) {
            Log.e(TAG, "Error collecting call log", e)
        }

        if (records.isNotEmpty()) {
            prefs.lastCallSync = System.currentTimeMillis()
        }

        Log.d(TAG, "Collected ${records.size} call records")
        return records
    }

    // ─── App Usage ───────────────────────────────────────────────────────────

    fun collectAppUsage(): List<AppUsageRecord> {
        val usageStatsManager = context.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
            ?: return emptyList()

        val dateFormat = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
        val today = dateFormat.format(Date())

        val cal = Calendar.getInstance()
        cal.set(Calendar.HOUR_OF_DAY, 0)
        cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        val startOfDay = cal.timeInMillis

        val stats = usageStatsManager.queryUsageStats(
            UsageStatsManager.INTERVAL_DAILY,
            startOfDay,
            System.currentTimeMillis()
        )

        val records = mutableListOf<AppUsageRecord>()

        stats?.filter { it.totalTimeInForeground > 0 }?.forEach { stat ->
            val appName = try {
                val appInfo = packageManager.getApplicationInfo(stat.packageName, 0)
                packageManager.getApplicationLabel(appInfo).toString()
            } catch (e: PackageManager.NameNotFoundException) {
                stat.packageName
            }

            records.add(
                AppUsageRecord(
                    packageName = stat.packageName,
                    appName = appName,
                    totalTimeMs = stat.totalTimeInForeground,
                    lastUsed = Timestamp(Date(stat.lastTimeUsed)),
                    date = today
                )
            )
        }

        // Sort by most used
        records.sortByDescending { it.totalTimeMs }

        Log.d(TAG, "Collected usage stats for ${records.size} apps")
        return records
    }

    // ─── Helper ──────────────────────────────────────────────────────────────

    private fun lookupContactName(number: String): String {
        return try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                Uri.encode(number)
            )
            val cursor = contentResolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                null, null, null
            )
            cursor?.use {
                if (it.moveToFirst()) {
                    it.getString(it.getColumnIndexOrThrow(ContactsContract.PhoneLookup.DISPLAY_NAME))
                } else null
            } ?: number
        } catch (e: Exception) {
            number
        }
    }

    companion object {
        private const val TAG = "DataCollectors"
    }
}
