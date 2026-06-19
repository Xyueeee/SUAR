package com.example.suar_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

/// Keeps BLE advertising/scanning alive under battery optimisation, per
/// CLAUDE.md "FOREGROUND SERVICE" requirement.
class MeshForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "suar_mesh_channel"
        const val NOTIFICATION_ID = 1
        const val EXTRA_STATUS_TEXT = "status_text"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val statusText = intent?.getStringExtra(EXTRA_STATUS_TEXT) ?: "SUAR Mesh Active"
        startForeground(NOTIFICATION_ID, buildNotification(statusText))
        return START_STICKY
    }

    private fun buildNotification(statusText: String): Notification {
        createNotificationChannelIfNeeded()
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("SUAR Mesh Active")
            .setContentText(statusText)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .build()
    }

    private fun createNotificationChannelIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(CHANNEL_ID, "SUAR Mesh", NotificationManager.IMPORTANCE_LOW)
            manager.createNotificationChannel(channel)
        }
    }
}
