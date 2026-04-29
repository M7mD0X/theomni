package com.omniide.omni_ide

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private val guardianChannel = "com.omniide/guardian"
    private val nativeChannel = "com.omniide/native"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, guardianChannel)
            .setMethodCallHandler { call, result -> handleGuardian(call, result) }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, nativeChannel)
            .setMethodCallHandler { call, result -> handleNative(call, result) }
    }

    // ── Guardian (foreground service) ───────────────────────────────────
    private fun handleGuardian(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startGuardian" -> {
                val localMode = call.argument<Boolean>("localMode") ?: false
                startGuardianService(localMode)
                result.success("Guardian Running")
            }
            "stopGuardian" -> {
                stopService(Intent(this, GuardianService::class.java))
                result.success("Guardian Stopped")
            }
            else -> result.notImplemented()
        }
    }

    private fun startGuardianService(localMode: Boolean) {
        val intent = Intent(this, GuardianService::class.java).apply {
            putExtra(GuardianService.EXTRA_LOCAL_MODE, localMode)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    // ── Native bridge (Termux check, storage, file I/O) ─────────────────
    private fun handleNative(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "isTermuxInstalled" -> result.success(isPackageInstalled("com.termux"))

                "openTermux" -> {
                    val intent = packageManager.getLaunchIntentForPackage("com.termux")
                    if (intent != null) {
                        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        startActivity(intent)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }

                "hasStoragePermission" -> result.success(hasStoragePermission())

                "requestStoragePermission" -> {
                    requestStoragePermission()
                    result.success(true)
                }

                "ensureWorkspace" -> {
                    val path = ensureWorkspace()
                    result.success(path)
                }

                "listDir" -> {
                    val path = call.argument<String>("path") ?: ""
                    result.success(listDir(path))
                }

                "readFile" -> {
                    val path = call.argument<String>("path") ?: ""
                    result.success(readFile(path))
                }

                "writeFile" -> {
                    val path = call.argument<String>("path") ?: ""
                    val content = call.argument<String>("content") ?: ""
                    result.success(writeFile(path, content))
                }

                "mkdir" -> {
                    val path = call.argument<String>("path") ?: ""
                    val ok = File(path).mkdirs() || File(path).isDirectory
                    result.success(ok)
                }

                "deletePath" -> {
                    val path = call.argument<String>("path") ?: ""
                    result.success(File(path).deleteRecursively())
                }

                "renamePath" -> {
                    val from = call.argument<String>("from") ?: ""
                    val to = call.argument<String>("to") ?: ""
                    val src = File(from)
                    val dst = File(to)
                    dst.parentFile?.mkdirs()
                    result.success(src.renameTo(dst))
                }

                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("NATIVE_ERR", e.message, null)
        }
    }

    private fun isPackageInstalled(pkg: String): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(pkg, 0)
        }
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    private fun hasStoragePermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            // Pre-R: legacy permissions are declared in manifest; treat as granted
            // since the runtime permission flow is handled at install time on those APIs
            // for the IDE use-case. (We could wire a full permission_handler here later.)
            true
        }
    }

    private fun requestStoragePermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val intent = try {
            Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                data = Uri.parse("package:$packageName")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
        } catch (_: Exception) {
            Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
        }
        startActivity(intent)
    }

    private fun ensureWorkspace(): String {
        val root = "/storage/emulated/0/OmniIDE"
        try { File(root).mkdirs() } catch (_: Exception) {}
        try { File("$root/projects").mkdirs() } catch (_: Exception) {}
        return root
    }

    private fun listDir(path: String): List<Map<String, Any?>> {
        val dir = File(path)
        if (!dir.exists() || !dir.isDirectory) return emptyList()
        return (dir.listFiles() ?: emptyArray()).map {
            mapOf(
                "name" to it.name,
                "path" to it.absolutePath,
                "isDir" to it.isDirectory,
                "size" to (if (it.isDirectory) null else it.length()),
                "mtime" to it.lastModified()
            )
        }.sortedWith(compareBy({ !(it["isDir"] as Boolean) }, { (it["name"] as String).lowercase() }))
    }

    private fun readFile(path: String): Map<String, Any?> {
        val f = File(path)
        if (!f.exists() || !f.isFile) return mapOf("error" to "Not found")
        if (f.length() > 2 * 1024 * 1024) return mapOf("error" to "File too large (>2MB)")
        return mapOf(
            "content" to f.readText(Charsets.UTF_8),
            "absPath" to f.absolutePath,
            "size" to f.length()
        )
    }

    private fun writeFile(path: String, content: String): Boolean {
        val f = File(path)
        f.parentFile?.mkdirs()
        f.writeText(content, Charsets.UTF_8)
        return true
    }
}
