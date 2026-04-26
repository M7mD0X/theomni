import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Two operating modes for Omni-IDE.
///
///   • [cloud] — default for everyone. The Flutter app calls AI providers
///     directly over HTTPS. No agent, no Termux, no WebSocket. File tools are
///     read-only (we can read the device, but the agent cannot modify it).
///
///   • [local] — opt-in. Requires Termux + the agent script set up. Flutter
///     talks to ws://localhost:8080 and the agent has full read/write/shell
///     access through the agent.js tool registry.
enum AppMode { cloud, local }

class AppModeService extends ChangeNotifier {
  static const _kMode = 'app_mode';
  static const _kLocalEnabled = 'local_mode_enabled';
  static const _kFirstLaunchDone = 'first_launch_done';
  static const _kWorkspacePath = 'workspace_path';
  static const _native = MethodChannel('com.omniide/native');

  AppMode _mode = AppMode.cloud;
  AppMode get mode => _mode;

  bool _localEnabled = false;
  bool get localEnabled => _localEnabled;

  bool _termuxInstalled = false;
  bool get termuxInstalled => _termuxInstalled;

  String _workspacePath = '/storage/emulated/0/OmniIDE';
  String get workspacePath => _workspacePath;

  bool _firstLaunchDone = false;
  bool get firstLaunchDone => _firstLaunchDone;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _localEnabled = p.getBool(_kLocalEnabled) ?? false;
    _mode = (p.getString(_kMode) == 'local' && _localEnabled)
        ? AppMode.local
        : AppMode.cloud;
    _firstLaunchDone = p.getBool(_kFirstLaunchDone) ?? false;
    _workspacePath = p.getString(_kWorkspacePath) ?? _workspacePath;
    await refreshTermux();
    notifyListeners();
  }

  Future<void> refreshTermux() async {
    try {
      _termuxInstalled =
          await _native.invokeMethod<bool>('isTermuxInstalled') ?? false;
    } catch (_) {
      _termuxInstalled = false;
    }
    if (!_termuxInstalled && _mode == AppMode.local) {
      // Local mode requires Termux; fall back gracefully.
      _mode = AppMode.cloud;
      final p = await SharedPreferences.getInstance();
      await p.setString(_kMode, 'cloud');
    }
    notifyListeners();
  }

  Future<bool> setLocalEnabled(bool v) async {
    if (v && !_termuxInstalled) {
      await refreshTermux();
      if (!_termuxInstalled) return false;
    }
    _localEnabled = v;
    _mode = v ? AppMode.local : AppMode.cloud;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kLocalEnabled, v);
    await p.setString(_kMode, _mode == AppMode.local ? 'local' : 'cloud');
    notifyListeners();
    return true;
  }

  Future<void> markFirstLaunchDone() async {
    _firstLaunchDone = true;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kFirstLaunchDone, true);
    notifyListeners();
  }

  /// Ensures /storage/emulated/0/OmniIDE/ exists. Returns its absolute path.
  Future<String> ensureWorkspace() async {
    try {
      final res = await _native.invokeMethod<String>('ensureWorkspace');
      if (res != null && res.isNotEmpty) {
        _workspacePath = res;
        final p = await SharedPreferences.getInstance();
        await p.setString(_kWorkspacePath, res);
        notifyListeners();
      }
    } catch (_) {}
    return _workspacePath;
  }

  Future<bool> hasStoragePermission() async {
    try {
      return await _native.invokeMethod<bool>('hasStoragePermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestStoragePermission() async {
    try {
      await _native.invokeMethod('requestStoragePermission');
    } catch (_) {}
  }

  Future<void> openTermux() async {
    try {
      await _native.invokeMethod<bool>('openTermux');
    } catch (_) {}
  }
}
