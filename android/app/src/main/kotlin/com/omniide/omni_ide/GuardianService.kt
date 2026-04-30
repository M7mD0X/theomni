package com.omniide.omni_ide

import android.app.*
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
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
 *   • BUG-010 fix: Properly handles START_STICKY restart with null intent
 *     by using in-memory mode tracking alongside SharedPreferences.
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
        private const val TAG = "GuardianService"
    }

    @Volatile private var nodeProcess: Process? = null
    private val handler = Handler(Looper.getMainLooper())
    private var consecutiveFailures = 0
    private var isRunning = false

    // BUG-010 fix: Track the mode in memory so START_STICKY restart with null intent
    // doesn't fall back to potentially stale SharedPreferences.
    @Volatile private var lastKnownLocalMode: Boolean = false

    private val healthCheckRunnable = object : Runnable {
        override fun run() {
            if (!isRunning) return
            // BUG-010 fix: Use in-memory mode instead of re-reading SharedPreferences
            if (lastKnownLocalMode) {
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
                Log.i(TAG, "Stop action received")
                stopAgent()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_RESTART -> {
                Log.i(TAG, "Restart action received")
                stopAgent()
                // BUG-010 fix: Use in-memory mode for restart
                if (lastKnownLocalMode) {
                    Thread { startAgentProcess() }.start()
                }
                return START_STICKY
            }
        }

        // BUG-010 fix: When START_STICKY restarts the service with a null intent,
        // use the in-memory tracked mode instead of relying on SharedPreferences
        // which may not have committed yet.
        val localMode = if (intent != null) {
            // Fresh start with an explicit intent — read mode from intent + prefs
            val explicit = intent.getBooleanExtra(EXTRA_LOCAL_MODE, false)
            val persisted = prefs().getBoolean(KEY_LOCAL_MODE, false)
            val mode = explicit || persisted
            lastKnownLocalMode = mode
            mode
        } else {
            // START_STICKY restart with null intent — use last known mode.
            // If we don't have a last known mode, fall back to SharedPreferences.
            if (lastKnownLocalMode) {
                true
            } else {
                prefs().getBoolean(KEY_LOCAL_MODE, false).also {
                    lastKnownLocalMode = it
                }
            }
        }

        Log.i(TAG, "onStartCommand: localMode=$localMode, intent=${intent?.action ?: "null"}")
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
        Log.i(TAG, "onDestroy")
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
            Log.w(TAG, "Agent script not found: $script")
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
            // VULN-005 fix: Don't pass API key via environment variables
            // that are visible to other apps. The key is sent securely
            // via the WebSocket connection after the agent starts.
            nodeProcess = pb.start()

            // Give it a few seconds to start up, then check health
            Thread.sleep(3000)

            if (isAgentHealthy()) {
                consecutiveFailures = 0
                updateNotification(localMode = true, status = "running")
                Log.i(TAG, "Agent started successfully")
            } else {
                updateNotification(localMode = true, status = "starting")
                Log.i(TAG, "Agent starting... (health check pending)")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start agent: ${e.message}")
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
                Log.i(TAG, "Agent process stopped")
            } catch (e: Exception) {
                Log.w(TAG, "Error stopping agent: ${e.message}")
            }
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
            } catch (e: Exception) {
                Log.w(TAG, "Error killing existing agent: ${e.message}")
            }
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
        } catch (e: Exception) {
            Log.d(TAG, "Agent health check failed: ${e.message}")
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
        Log.w(TAG, "Agent health check failed (attempt $consecutiveFailures)")

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
