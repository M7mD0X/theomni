/// Agent service interface — defines the contract every agent backend must
/// satisfy.  Consumers (widgets, screens) should depend on *this* type so
/// swapping cloud / local / mock implementations requires zero changes
/// downstream.
///
/// Extends [ChangeNotifier] so that any implementation can be used directly
/// with Flutter's `Consumer<T>` / `context.watch<T>()` provider pattern.
library;

import 'package:flutter/foundation.dart';
import 'agent_service.dart' show AgentMessage, AgentState;

abstract class AgentServiceInterface extends ChangeNotifier {
  // ── Observable state ──────────────────────────────────────────────────

  /// Current connection lifecycle state.
  AgentState get state;

  /// Human-readable status string shown in the UI status strip.
  String get statusText;

  /// Conversation history (read-only snapshot).
  List<AgentMessage> get messages;

  // ── Connection ────────────────────────────────────────────────────────

  /// Open a connection.  Behaviour depends on the mode (cloud vs local).
  ///
  /// [fromUser] – when `true`, signals an explicit user tap rather than an
  /// automatic background attempt; implementations may use this to reset
  /// retry counters.
  Future<void> connect({bool fromUser = false});

  /// Lightweight probe to check if the agent backend is reachable.
  ///
  /// Returns a short identifier string on success (e.g. model name) or
  /// `null` when unreachable.
  Future<String?> ping();

  // ── Messaging ─────────────────────────────────────────────────────────

  /// Append a user message and send it to the agent.
  void sendMessage(String text);

  /// Remove all messages from the conversation history.
  void clearMessages();

  // ── Configuration ─────────────────────────────────────────────────────

  /// Re-send the current provider / model / API key config to the agent.
  ///
  /// Meaningful only in local mode; cloud mode reads settings on every call
  /// and can safely no-op.
  Future<void> reloadConfig();

  // ── Local-mode retry (optional capabilities) ─────────────────────────

  /// Whether automatic reconnection is enabled.
  bool get autoRetry;

  /// Seconds until the next automatic retry (0 when not counting down).
  int get retryCountdown;

  /// Toggle automatic reconnection on/off.
  void setAutoRetry(bool value);
}
