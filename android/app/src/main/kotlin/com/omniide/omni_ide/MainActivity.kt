package com.omniide.omni_ide

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channel = "com.omniide/guardian"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channel
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startGuardian" -> {
                    startGuardianService()
                    result.success("Guardian Running")
                }
                "stopGuardian" -> {
                    stopService(Intent(this, GuardianService::class.java))
                    result.success("Guardian Stopped")
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startGuardianService() {
        val intent = Intent(this, GuardianService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}