# ============================================================================
# Omni-IDE ProGuard / R8 rules
# ============================================================================

# Flutter / Dart embedding
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**

# Kotlin
-keep class kotlin.Metadata { *; }
-dontwarn kotlinx.**

# Omni-IDE Guardian native bridge (MethodChannel handlers)
-keep class com.omniide.omni_ide.** { *; }

# AndroidX / Foreground service
-keep class androidx.core.app.NotificationCompat** { *; }

# Keep line numbers for crash reports
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# JSON / reflection used by web_socket_channel + http
-keepattributes Signature
-keepattributes *Annotation*
