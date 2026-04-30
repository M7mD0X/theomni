/// Agent Launcher — Professional multi-strategy agent startup system.

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../app_mode_service.dart';

// ── Result type ─────────────────────────────────────────────────────────────

/// The outcome of a launch attempt.
enum LaunchResult {
  /// Agent is confirmed running (health check passed).
  started,

  /// Agent was already running — no action needed.
  alreadyRunning,

  /// The selected strategy isn't available on this device.
  strategyUnavailable,

  /// The launch was attempted but the agent didn't become healthy
  /// within the timeout.
  failed,

  /// The user cancelled (e.g. decided not to install Termux).
  cancelled,
}

// ── Strategies ──────────────────────────────────────────────────────────────

/// Available strategies for starting the local agent.
enum LaunchStrategy {
  /// Use `Termux:RunCommand` intent — fires the start script without
  /// the user leaving the app. Requires the Termux:API plugin.
  termuxRun,

  /// Execute a simplified quick-start script via the native
  /// MethodChannel. Fastest path for users who already have Termux
  /// but not the API plugin.
  quickStart,

  /// Show the start command and let the user copy-paste it into
  /// Termux manually. Always works, zero dependencies beyond Termux.
  manual,
}

// ── Launcher ────────────────────────────────────────────────────────────────

class AgentLauncher {
  final AppModeService _mode;
  static const _native = MethodChannel('com.omniide/native');
  static const _agentUrl = 'http://localhost:8080';

  /// How long to wait for the agent to become healthy after launch.
  static const _healthTimeout = Duration(seconds: 15);

  /// Interval between health-check probes.
  static const _probeInterval = Duration(milliseconds: 800);

  AgentLauncher(this._mode);

  // ── Public API ──────────────────────────────────────────────────────────

  /// Start the agent using the given [strategy].
  ///
  /// Returns [LaunchResult.started] if the agent is confirmed healthy,
  /// or another result indicating what happened.
  Future<LaunchResult> start(LaunchStrategy strategy) async {
    // 1. Check if already running — short-circuit.
    if (await _probeHealth()) return LaunchResult.alreadyRunning;

    // 2. Ensure Termux is installed (required for all local strategies).
    if (!_mode.termuxInstalled) {
      await _mode.refreshTermux();
      if (!_mode.termuxInstalled) return LaunchResult.strategyUnavailable;
    }

    // 3. Execute the chosen strategy.
    switch (strategy) {
      case LaunchStrategy.termuxRun:
        return _launchViaTermuxRun();
      case LaunchStrategy.quickStart:
        return _launchViaQuickStart();
      case LaunchStrategy.manual:
        return LaunchResult.cancelled; // manual = user must act
    }
  }

  /// Attempt strategies in order of preference, falling back gracefully.
  ///
  /// Order: Termux:Run → Quick-start → Manual
  Future<LaunchResult> startAuto() async {
    // Probe first
    if (await _probeHealth()) return LaunchResult.alreadyRunning;

    // Try Termux:Run (seamless)
    if (_mode.termuxInstalled) {
      final r = await _launchViaTermuxRun();
      if (r == LaunchResult.started) return r;
    }

    // Try quick-start via native channel
    if (_mode.termuxInstalled) {
      final r = await _launchViaQuickStart();
      if (r == LaunchResult.started) return r;
    }

    // Fall back to manual
    return LaunchResult.cancelled;
  }

  /// Quick health probe — returns true if the agent is reachable.
  Future<bool> isAgentHealthy() => _probeHealth();

  // ── Strategy implementations ────────────────────────────────────────────

  /// **Strategy 1: Termux:RunCommand intent**
  ///
  /// Sends a `RUN_COMMAND` intent to the Termux:API app, which runs
  /// the start script in the background. The user never leaves Omni-IDE.
  Future<LaunchResult> _launchViaTermuxRun() async {
    try {
      final result = await _native.invokeMethod<bool>('startAgentViaTermux');
      if (result == true) {
        return _waitForHealthy();
      }
    } catch (e) {
      debugPrint('[AgentLauncher] Termux run strategy failed: $e');
    }
    return LaunchResult.strategyUnavailable;
  }

  /// **Strategy 2: Quick-start via native channel**
  ///
  /// Calls a native method that spawns `sh ~/omni-ide/start_agent.sh`
  /// through Termux's shell environment. Slightly more intrusive than
  /// the intent approach but works without the API plugin.
  Future<LaunchResult> _launchViaQuickStart() async {
    try {
      final result = await _native.invokeMethod<bool>('startAgentQuick');
      if (result == true) {
        return _waitForHealthy();
      }
    } catch (e) {
      debugPrint('[AgentLauncher] Quick start strategy failed: $e');
    }
    return LaunchResult.strategyUnavailable;
  }

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
      debugPrint('[AgentLauncher] Health probe failed: $e');
      return false;
    }
  }

  /// Wait for the agent to become healthy after a launch attempt.
  /// Polls the `/health` endpoint with exponential backoff.
  Future<LaunchResult> _waitForHealthy() async {
    final deadline = DateTime.now().add(_healthTimeout);
    int attempt = 0;

    while (DateTime.now().isBefore(deadline)) {
      // Wait before first probe (agent needs time to start)
      await Future.delayed(
        attempt == 0
            ? const Duration(seconds: 2)
            : _probeInterval,
      );
      attempt++;

      if (await _probeHealth()) {
        return LaunchResult.started;
      }
    }

    return LaunchResult.failed;
  }
}
