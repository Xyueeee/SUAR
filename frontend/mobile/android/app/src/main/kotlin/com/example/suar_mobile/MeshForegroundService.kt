package com.example.suar_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.provider.Settings

/// Keeps BLE advertising/scanning alive under battery optimisation, per
/// CLAUDE.md "FOREGROUND SERVICE" requirement.
class MeshForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "suar_mesh_channel"
        const val NOTIFICATION_ID = 1
        const val EXTRA_STATUS_TEXT = "status_text"
        const val EXTRA_DETAIL_TEXT = "detail_text"
        const val EXTRA_WIFI_ACTION = "wifi_action"
        // Stop request routed THROUGH the service (see MainActivity.stopMeshService).
        // A plain Context.stopService() while a startForegroundService() is still
        // pending is fatal on Android 14+: the system logs "Bringing down service
        // while still waiting for start foreground" and kills the app with
        // ForegroundServiceDidNotStartInTimeException (confirmed on the S926B:
        // RadioStatusBanner's updateMeshStatus landed 23ms before the mode-exit
        // stopService and crashed Victim-mode exit). Delivering the stop as one
        // more start lets onStartCommand call startForeground() first — paying
        // off every pending obligation — and only then stop itself.
        const val EXTRA_STOP = "stop_service"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val statusText = intent?.getStringExtra(EXTRA_STATUS_TEXT) ?: "SUAR Mesh Active"
        val detailText = intent?.getStringExtra(EXTRA_DETAIL_TEXT)
        val wifiAction = intent?.getBooleanExtra(EXTRA_WIFI_ACTION, false) ?: false
        // On API 34+, startForeground() throws StartForegroundException if the
        // connectedDevice precondition (active BT/WiFi Direct) is no longer met —
        // this happens in a stop-race where startForegroundService() was queued
        // just before the radios were torn down. Catch it and stop cleanly instead
        // of letting the uncaught exception cause ForegroundServiceDidNotStartInTimeException.
        try {
            startForeground(NOTIFICATION_ID, buildNotification(statusText, detailText, wifiAction))
        } catch (e: Exception) {
            stopSelf()
            return START_NOT_STICKY
        }
        // Stop request (see EXTRA_STOP above): the startForeground() call above
        // has already discharged any pending start obligation, so stopping here
        // is safe where a bare Context.stopService() from the Activity was not.
        if (intent?.getBooleanExtra(EXTRA_STOP, false) == true) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        // This service owns nothing but the notification — the actual BLE
        // advertiser/GATT server and Wi-Fi Direct server live in
        // MainActivity's helpers, a completely separate component. If the
        // OS killed this service for memory and START_STICKY restarted it,
        // the result would be a "Mesh Active" notification resurrected with
        // no mesh activity behind it (the radios it claims to represent
        // would just be gone) — actively misleading instead of accurate.
        // START_NOT_STICKY lets it disappear honestly instead.
        return START_NOT_STICKY
    }

    private fun buildNotification(
        statusText: String,
        detailText: String?,
        wifiAction: Boolean
    ): Notification {
        createNotificationChannelIfNeeded()
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setContentTitle("SUAR Mesh Active")
            // Collapsed view stays one short line; the long explanation only
            // appears when the user expands the notification — keeps the shade
            // tidy instead of showing a wall of text inline.
            .setContentText(statusText)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
        if (!detailText.isNullOrEmpty()) {
            builder.style = Notification.BigTextStyle().bigText(detailText)
        }
        // A one-tap "Wi-Fi settings" action so a radio problem (off / joined to
        // a network / P2P unavailable) can be fixed straight from the shade,
        // without finding and opening the app first — important when the phone
        // may be in someone else's hand during a response.
        if (wifiAction) {
            val settingsIntent = Intent(Settings.ACTION_WIFI_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val pending = PendingIntent.getActivity(
                this,
                0,
                settingsIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            builder.addAction(
                Notification.Action.Builder(
                    null,
                    "Wi-Fi settings",
                    pending
                ).build()
            )
        }
        return builder.build()
    }

    private fun createNotificationChannelIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(CHANNEL_ID, "SUAR Mesh", NotificationManager.IMPORTANCE_LOW)
            manager.createNotificationChannel(channel)
        }
    }
}
