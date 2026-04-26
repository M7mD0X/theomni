# Omni-IDE Build System

A real, production-grade Android build pipeline — no `flutter create temp_app` hacks, no surprises.

## TL;DR

| What | How |
|------|-----|
| Build APKs locally | `flutter build apk --debug` (or `--release`) |
| Build a release tag | Run **Actions → Bump version & Tag** (manual) |
| CI builds on every push | `.github/workflows/build.yml` |
| Nightly canary against Flutter `master` | `.github/workflows/nightly.yml` |

## Toolchain (latest stable, Jan 2026)

| Component       | Version |
|-----------------|---------|
| Flutter         | `stable` channel (auto-resolved in CI) |
| Gradle          | 8.14.4 |
| Android Gradle Plugin | 8.7.3 |
| Kotlin          | 2.1.0 |
| JDK             | 17 (Zulu) |
| compileSdk / targetSdk | 35 |
| minSdk          | 21 |
| NDK ABIs        | armeabi-v7a, arm64-v8a, x86_64 |

## Repository layout

```
android/
├── build.gradle                # root project config
├── settings.gradle             # Flutter plugin loader + plugin versions
├── gradle.properties           # JVM args, R8 full mode, AndroidX, parallel
├── gradlew, gradlew.bat        # wrapper scripts
├── gradle/wrapper/             # gradle-wrapper.{jar,properties}
├── local.properties.example    # template — copy to local.properties
└── app/
    ├── build.gradle            # app module: signing, splits, R8, version-from-pubspec
    ├── proguard-rules.pro      # Flutter + Guardian-safe shrink rules
    └── src/
        ├── main/
        │   ├── AndroidManifest.xml
        │   ├── kotlin/.../MainActivity.kt
        │   ├── kotlin/.../GuardianService.kt
        │   └── res/            # icons, themes, launch background, colors
        ├── debug/AndroidManifest.xml      # adds INTERNET for hot reload
        └── profile/AndroidManifest.xml
key.properties.example          # template for release signing
analysis_options.yaml           # lints
test/smoke_test.dart            # unit-test harness
.github/workflows/
├── build.yml                   # main pipeline
├── nightly.yml                 # canary
└── release.yml                 # bump + tag helper
```

## Versioning

`pubspec.yaml` is the single source of truth:

```yaml
version: 2.0.0+2
#        ^name ^code
```

* `app/build.gradle` reads it and applies it as `versionName` / `versionCode`.
* CI overrides `versionCode` with `GITHUB_RUN_NUMBER` if higher (so Play Store builds are always monotonic).
* On a `v*.*.*` tag, the tag itself becomes the `versionName`.

## Building locally

```bash
# 1. Point Gradle at your Flutter SDK
cp android/local.properties.example android/local.properties
# edit local.properties with your real flutter.sdk and sdk.dir paths

# 2. Build
flutter pub get
flutter build apk --debug                # debug
flutter build apk --release              # release (debug-signed if no key.properties)
flutter build apk --release --split-per-abi  # one APK per ABI + universal
flutter build appbundle --release        # AAB for Play Store
```

## Release signing (optional)

Generate a keystore once:

```bash
keytool -genkey -v -keystore upload-keystore.jks \
        -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Then either:

**Locally** — copy `key.properties.example` → `key.properties`, fill in real paths.

**In CI** — add four repository secrets:

| Secret | Value |
|--------|-------|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 upload-keystore.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | the store password |
| `ANDROID_KEY_ALIAS` | `upload` (or whatever you chose) |
| `ANDROID_KEY_PASSWORD` | the key password |

If the secrets are absent the workflow falls back to debug-signed release APKs — the build still succeeds.

## Cutting a release

1. Go to **Actions → Omni-IDE • Bump version & Tag → Run workflow**
2. Pick `patch` / `minor` / `major` (and optional prerelease suffix like `rc.1`)
3. The workflow bumps `pubspec.yaml`, commits it, and pushes a `vX.Y.Z` tag
4. The main build workflow picks up the tag and:
   * builds debug + release APKs (split per ABI + universal) + AAB
   * uploads everything to a brand-new GitHub Release
   * auto-generates changelog from `git log` since the previous tag

## Pipeline at a glance

```
push / PR / tag
      │
      ▼
┌──────────────┐   ┌─────────────┐   ┌────────────────────────┐   ┌─────────────────┐
│  analyze &   │──▶│  metadata   │──▶│ build (matrix: dbg/rel)│──▶│ release (on tag)│
│    test      │   │ versionName │   │   • split-per-ABI      │   │   • changelog   │
│  flutter     │   │ versionCode │   │   • universal APK      │   │   • upload APKs │
│  analyze +   │   │   release?  │   │   • AAB on tag         │   │   • upload AAB  │
│  unit tests  │   └─────────────┘   │   • size summary       │   └─────────────────┘
└──────────────┘                     └────────────────────────┘
```

Concurrency control cancels stale runs on the same ref. All jobs run in parallel where possible. Gradle + pub caches make incremental CI runs ~3× faster.
