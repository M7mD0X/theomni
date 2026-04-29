package com.omniide.omni_ide

import android.app.*
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * Foreground service that manages the Node.js agent lifecycle.
 *
 * Key improvements over v1:
 *   • Health-check polling: verifies agent is actually responding, not just
 *     that the process exists.
 *   • Automatic restart on crash: if the health check fails, kills the stale
 *     process and starts a fresh one.
 *   • Single-instance guarantee: PID file prevents duplicate agents.
 *   • Clean shutdown: sends SIGTERM and waits before SIGKILL.
 *   • Notification reflects real agent status (running / restarting / stopped).
 */
class GuardianService : Service() {

    companion object {
        const val CHANNEL_ID = "OmniIDEGuardian"
        const val NOTIFICATION_ID = 1
        const val ACTION_STOP = "com.omniide.STOP_GUARDIAN"
        const val ACTION_RESTART = "com.omniide.RESTART_AGENT"
        const val EXTRA_LOCAL_MODE = "local_mode"
        const val PREFS = "FlutterSharedPreferences"
        const val KEY_LOCAL_MODE = "flutter.local_mode_enabled"
        private const val HEALTH_CHECK_INTERVAL_MS = 15_000L // 15 seconds
        private const val AGENT_PORT = 8080
    }

    @Volatile private var nodeProcess: Process? = null
    private val handler = Handler(Looper.getMainLooper())
    private var consecutiveFailures = 0
    private var isRunning = false

    private val healthCheckRunnable = object : Runnable {
        override fun run() {
            if (!isRunning) return
            if (prefs().getBoolean(KEY_LOCAL_MODE, false)) {
                checkAndRestartIfNeeded()
            }
            handler.postDelayed(this, HEALTH_CHECK_INTERVAL_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification(localMode = false, status = "idle"))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopAgent()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_RESTART -> {
                stopAgent()
                val localMode = prefs().getBoolean(KEY_LOCAL_MODE, false)
                if (localMode) {
                    Thread { startAgentProcess() }.start()
                }
                return START_STICKY
            }
        }

        val explicit = intent?.getBooleanExtra(EXTRA_LOCAL_MODE, false) == true
        val persisted = prefs().getBoolean(KEY_LOCAL_MODE, false)
        val localMode = explicit || persisted

        isRunning = true

        if (localMode) {
            updateNotification(localMode = true, status = "starting")
            Thread { startAgentProcess() }.start()
            handler.postDelayed(healthCheckRunnable, HEALTH_CHECK_INTERVAL_MS)
        } else {
            stopAgent()
            updateNotification(localMode = false, status = "idle")
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        isRunning = false
        handler.removeCallbacks(healthCheckRunnable)
        stopAgent()
        super.onDestroy()
    }

    // ── Agent lifecycle ─────────────────────────────────────────────────

    private fun startAgentProcess() {
        // Check if agent is already healthy
        if (isAgentHealthy()) {
            updateNotification(localMode = true, status = "running")
            return
        }

        // Kill any existing process first
        killExistingAgent()

        val script = "/data/data/com.termux/files/home/omni-ide/start_agent.sh"
        if (!File(script).exists()) {
            updateNotification(localMode = true, status = "no agent")
            return
        }

        try {
            val pb = ProcessBuilder(
                "/data/data/com.termux/files/usr/bin/bash",
                script
            )
            pb.redirectErrorStream(true)
            pb.environment()["OMNI_PORT"] = AGENT_PORT.toString()
            nodeProcess = pb.start()

            // Give it a few seconds to start up, then check health
            Thread.sleep(3000)

            if (isAgentHealthy()) {
                consecutiveFailures = 0
                updateNotification(localMode = true, status = "running")
            } else {
                updateNotification(localMode = true, status = "starting")
            }
        } catch (e: Exception) {
            updateNotification(localMode = true, status = "error")
        }
    }

    private fun stopAgent() {
        nodeProcess?.let { proc ->
            try {
                // Send SIGTERM for graceful shutdown
                proc.outputStream.close()
                proc.destroy()
                // Wait up to 3 seconds for clean exit
                val exited = proc.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)
                if (!exited) {
                    proc.destroyForcibly()
                }
            } catch (_: Exception) {}
        }
        nodeProcess = null
        killExistingAgent()
    }

    /**
     * Kill any agent process tracked in the PID file.
     */
    private fun killExistingAgent() {
        val pidFile = File("/data/data/com.termux/files/home/omni-ide/agent.pid")
        if (pidFile.exists()) {
            try {
                val pid = pidFile.readText().trim().toIntOrNull()
                if (pid != null) {
                    val proc = Runtime.getRuntime().exec(arrayOf("kill", pid.toString()))
                    proc.waitFor(2, java.util.concurrent.TimeUnit.SECONDS)
                }
            } catch (_: Exception) {}
            pidFile.delete()
        }
    }

    /**
     * Check if the agent is healthy by hitting /health endpoint.
     */
    private fun isAgentHealthy(): Boolean {
        return try {
            val url = URL("http://localhost:$AGENT_PORT/health")
            val conn = url.openConnection() as HttpURLConnection
            conn.requestMethod = "GET"
            conn.connectTimeout = 2000
            conn.readTimeout = 2000
            val code = conn.responseCode
            conn.disconnect()
            code == 200
        } catch (_: Exception) {
            false
        }
    }

    private fun checkAndRestartIfNeeded() {
        if (isAgentHealthy()) {
            consecutiveFailures = 0
            updateNotification(localMode = true, status = "running")
            return
        }

        consecutiveFailures++
        updateNotification(localMode = true, status = "reconnecting")

        // After 3 consecutive failures, try restarting
        if (consecutiveFailures >= 3) {
            Thread {
                stopAgent()
                Thread.sleep(1000)
                startAgentProcess()
                consecutiveFailures = 0
            }.start()
        }
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

    private fun updateNotification(localMode: Boolean, status: String) {
        val notification = buildNotification(localMode, status)
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIFICATION_ID, notification)
    }

    private fun buildNotification(localMode: Boolean, status: String): Notification {
        val stopIntent = PendingIntent.getService(
            this, 0,
            Intent(this, GuardianService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_IMMUTABLE
        )

        val restartIntent = PendingIntent.getService(
            this, 1,
            Intent(this, GuardianService::class.java).apply { action = ACTION_RESTART },
            PendingIntent.FLAG_IMMUTABLE
        )

        val title = when {
            !localMode -> "Cloud Mode"
            status == "running" -> "Agent Running"
            status == "starting" -> "Agent Starting..."
            status == "reconnecting" -> "Reconnecting..."
            status == "no agent" -> "Agent Not Installed"
            status == "error" -> "Agent Error"
            else -> "Omni-IDE"
        }

        val text = when {
            !localMode -> "Cloud mode · idle"
            status == "running" -> "Full Access · connected on :$AGENT_PORT"
            status == "starting" -> "Starting agent process..."
            status == "reconnecting" -> "Connection lost · retrying..."
            status == "no agent" -> "Run setup in Termux first"
            status == "error" -> "Agent failed to start"
            else -> status
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_media_play, "Restart", restartIntent)
            .addAction(android.R.drawable.ic_delete, "Stop", stopIntent)
            .build()
    }
}
