// Agent Bootstrap — unified startup lifecycle manager.
//
// Provides a single, simple entry point for starting the agent with automatic
// strategy selection. Callers don't need to know about Termux, launch
// strategies, or health checks — just call [start()] and handle the result.
//
// The bootstrap process follows this flow:
//   1. If cloud mode → no startup needed
//   2. If agent is already healthy → return immediately
//   3. If local mode → try auto-launch (Termux:Run → Quick-start → Manual)
//   4. Connect to the started agent

import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../agent_interface.dart';
import '../app_mode_service.dart';
import '../settings_service.dart';
import 'agent_factory.dart';
import 'agent_launcher.dart';

// ── Result type ─────────────────────────────────────────────────────────────

/// The outcome of a bootstrap attempt.
enum BootstrapResult {
  /// Agent is ready to use (either was already running or just started).
  ready,

  /// Agent is in cloud mode — always ready, no startup needed.
  cloudReady,

  /// The agent couldn't be started (all strategies failed).
  failed,

  /// Termux is not installed — required for local mode.
  termuxRequired,

  /// The user needs to manually start the agent (copy-paste command).
  manualRequired,
}

// ── Bootstrap ───────────────────────────────────────────────────────────────

class AgentBootstrap {
  final AppModeService _mode;
  final SettingsService _settings;

  static const _native = MethodChannel('com.omniide/native');
  static const _agentUrl = 'http://localhost:8080';

  /// How long to wait for the agent to become healthy after launch.
  static const _healthTimeout = Duration(seconds: 15);

  /// Interval between health-check probes.
  static const _probeInterval = Duration(milliseconds: 800);

  /// The command users can copy-paste into Termux as a fallback.
  static const manualCommand = '~/omni-ide/start_agent.sh';

  late final AgentLauncher _launcher;

  AgentBootstrap(this._mode, this._settings) {
    _launcher = AgentLauncher(_mode);
  }

  // ── Public API ──────────────────────────────────────────────────────────

  /// Start the agent using the best available strategy.
  ///
  /// In cloud mode, this is a no-op. In local mode, it tries:
  ///   1. Check if agent is already running
  ///   2. Auto-launch (Termux:Run → Quick-start)
  ///   3. Fall back to manual command
  Future<BootstrapResult> start() async {
    // Cloud mode never needs startup
    if (_mode.mode == AppMode.cloud) {
      return BootstrapResult.cloudReady;
    }

    // Already running?
    if (await _probeHealth()) {
      return BootstrapResult.ready;
    }

    // Need Termux for local mode
    if (!_mode.termuxInstalled) {
      await _mode.refreshTermux();
      if (!_mode.termuxInstalled) {
        return BootstrapResult.termuxRequired;
      }
    }

    // Try auto-launch
    final launchResult = await _launcher.startAuto();

    switch (launchResult) {
      case LaunchResult.started:
      case LaunchResult.alreadyRunning:
        return BootstrapResult.ready;
      case LaunchResult.failed:
        return BootstrapResult.failed;
      case LaunchResult.strategyUnavailable:
        // Auto strategies unavailable — user needs to start manually
        return BootstrapResult.manualRequired;
      case LaunchResult.cancelled:
        return BootstrapResult.manualRequired;
    }
  }

  /// Try a specific launch strategy.
  Future<BootstrapResult> startWithStrategy(LaunchStrategy strategy) async {
    if (_mode.mode == AppMode.cloud) {
      return BootstrapResult.cloudReady;
    }

    if (!_mode.termuxInstalled) {
      return BootstrapResult.termuxRequired;
    }

    final result = await _launcher.start(strategy);

    switch (result) {
      case LaunchResult.started:
      case LaunchResult.alreadyRunning:
        return BootstrapResult.ready;
      case LaunchResult.failed:
        return BootstrapResult.failed;
      case LaunchResult.strategyUnavailable:
        return BootstrapResult.manualRequired;
      case LaunchResult.cancelled:
        return BootstrapResult.manualRequired;
    }
  }

  /// Quick health probe — returns true if the agent is reachable.
  Future<bool> isAgentHealthy() => _probeHealth();

  /// Access the underlying launcher for advanced use cases.
  AgentLauncher get launcher => _launcher;

  // ── Health probing ──────────────────────────────────────────────────────

  Future<bool> _probeHealth() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 2);
      final req = await client.getUrl(Uri.parse('$_agentUrl/health'));
      final res = await req.close();
      client.close();
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[AgentBootstrap] Health check failed: $e');
      return false;
    }
  }
}
