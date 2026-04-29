// Agent service — thin facade that delegates to the correct implementation.
//
// This class maintains backward compatibility with code that references
// `AgentService` directly (e.g., `Provider<AgentService>`). Internally it
// delegates to either [CloudAgentService] or [LocalAgentService] depending
// on the current mode, and swaps implementations when the mode changes.
//
// New code should prefer depending on [AgentServiceInterface] for
// testability and loose coupling.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'agent/agent_interface.dart';
import 'agent/agent_launcher.dart';
import 'agent/agent_bootstrap.dart';
import 'agent/agent_factory.dart';
import 'app_mode_service.dart';
import 'settings_service.dart';

class AgentService extends ChangeNotifier implements AgentServiceInterface {
  static const startCommand = '~/omni-ide/start_agent.sh';
  static const agentUrl = 'http://localhost:8080';

  final SettingsService _settings;
  final AppModeService modeService;

  /// The active backend — swapped when mode changes.
  AgentServiceInterface _backend;

  /// Agent bootstrap for clean startup lifecycle.
  late final AgentBootstrap _bootstrap;

  AgentService(this.modeService, this._settings)
      : _backend = AgentFactory.create(modeService, _settings) {
    modeService.addListener(_onModeChanged);

    // Forward notifications from the backend
    _backend.addListener(_forwardNotify);

    // Initialize bootstrap
    _bootstrap = AgentBootstrap(modeService, _settings);
  }

  void _forwardNotify() => notifyListeners();

  void _onModeChanged() {
    final newBackend = AgentFactory.create(modeService, _settings);
    if (newBackend.runtimeType == _backend.runtimeType) return;

    // Swap backends
    _backend.removeListener(_forwardNotify);
    _backend.dispose();
    _backend = newBackend;
    _backend.addListener(_forwardNotify);

    // Auto-connect in local mode
    if (modeService.mode == AppMode.local) {
      _backend.connect();
    }

    notifyListeners();
  }

  // ── Bootstrap access ───────────────────────────────────────────────────────

  /// Access the agent bootstrap for clean startup lifecycle management.
  AgentBootstrap get bootstrap => _bootstrap;

  /// Access the agent launcher for starting the agent with multiple strategies.
  /// Prefer using [bootstrap] for the simpler API.
  AgentLauncher get launcher => _bootstrap.launcher;

  // ── Delegated interface ───────────────────────────────────────────────────

  @override
  AgentState get state => _backend.state;

  @override
  String get statusText => _backend.statusText;

  @override
  List<AgentMessage> get messages => _backend.messages;

  @override
  Future<void> connect({bool fromUser = false}) =>
      _backend.connect(fromUser: fromUser);

  @override
  Future<String?> ping() => _backend.ping();

  @override
  Future<bool> healthCheck() => _backend.healthCheck();

  @override
  Future<void> sendMessage(String text) => _backend.sendMessage(text);

  @override
  void clearMessages() => _backend.clearMessages();

  @override
  Future<void> reloadConfig() => _backend.reloadConfig();

  @override
  void cancelRequest() => _backend.cancelRequest();

  @override
  bool get autoRetry => _backend.autoRetry;

  @override
  int get retryCountdown => _backend.retryCountdown;

  @override
  void setAutoRetry(bool value) => _backend.setAutoRetry(value);

  // ── Convenience statics (used by UI for the "copy command" flow) ──────────

  /// Quick health check using the static URL.
  static Future<bool> quickHealthCheck() async {
    try {
      final res = await http
          .get(Uri.parse('$agentUrl/health'))
          .timeout(const Duration(seconds: 2));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    modeService.removeListener(_onModeChanged);
    _backend.removeListener(_forwardNotify);
    _backend.dispose();
    super.dispose();
  }
}
