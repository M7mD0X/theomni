package com.omniide.omni_ide

import android.app.*
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import java.io.File

/**
 * Foreground service that, when Local Mode is enabled, spawns the Node.js
 * agent (~/omni-ide/start_agent.sh in Termux) and keeps it alive. In Cloud
 * Mode it only displays the persistent notification — there is no agent
 * process to manage.
 */
class GuardianService : Service() {

    companion object {
        const val CHANNEL_ID = "OmniIDEGuardian"
        const val NOTIFICATION_ID = 1
        const val ACTION_STOP = "com.omniide.STOP_GUARDIAN"
        const val EXTRA_LOCAL_MODE = "local_mode"
        const val PREFS = "FlutterSharedPreferences"
        const val KEY_LOCAL_MODE = "flutter.local_mode_enabled"
    }

    @Volatile private var nodeProcess: Process? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification(localMode = false))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopAgent()
            stopSelf()
            return START_NOT_STICKY
        }

        // Local Mode flag may come from the launching intent OR from the
        // Flutter SharedPreferences (covers OS-restart scenarios).
        val explicit = intent?.getBooleanExtra(EXTRA_LOCAL_MODE, false) == true
        val persisted = prefs().getBoolean(KEY_LOCAL_MODE, false)
        val localMode = explicit || persisted

        startForeground(NOTIFICATION_ID, buildNotification(localMode))

        if (localMode) {
            startAgentIfNeeded()
        } else {
            stopAgent()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopAgent()
        super.onDestroy()
    }

    // ── Agent lifecycle ─────────────────────────────────────────────────
    private fun startAgentIfNeeded() {
        if (nodeProcess?.isAlive == true) return
        val script = "/data/data/com.termux/files/home/omni-ide/start_agent.sh"
        if (!File(script).exists()) return  // Termux setup hasn't run yet

        try {
            // Run the start script through Termux's bash; Termux must be installed
            // for this to work, which the Flutter side enforces before flipping
            // the local-mode toggle.
            val pb = ProcessBuilder(
                "/data/data/com.termux/files/usr/bin/bash",
                script
            )
            pb.redirectErrorStream(true)
            nodeProcess = pb.start()
        } catch (_: Exception) {
            nodeProcess = null
        }
    }

    private fun stopAgent() {
        try { nodeProcess?.destroy() } catch (_: Exception) {}
        nodeProcess = null
    }

    private fun prefs(): SharedPreferences =
        getSharedPreferences(PREFS, MODE_PRIVATE)

    // ── Notification ────────────────────────────────────────────────────
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Omni-IDE Guardian",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps the AI Agent alive"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(localMode: Boolean): Notification {
        val stopIntent = PendingIntent.getService(
            this, 0,
            Intent(this, GuardianService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_IMMUTABLE
        )

        val text = if (localMode) "Full Access Agent · running"
                   else "Cloud Mode · idle"

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Omni-IDE Active")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_delete, "Stop", stopIntent)
            .build()
    }
}
