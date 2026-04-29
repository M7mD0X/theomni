// Local-mode agent service — WebSocket bridge to the on-device agent.
//
// Connects to `ws://localhost:8080` and runs the full agent loop with
// streaming tokens, tool calls, and shell output. Handles auto-retry
// with exponential backoff and proper cancellation.
//
// Implements [AgentServiceInterface] so it can be swapped transparently.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import '../agent_interface.dart';
import '../settings_service.dart';
import 'throttled_notifications.dart';

class LocalAgentService extends ChangeNotifier
    with ThrottledNotifications
    implements AgentServiceInterface {
  final SettingsService _settings;

  static const agentUrl = 'http://localhost:8080';
  static const wsUrl = 'ws://localhost:8080';

  LocalAgentService(this._settings);

  // ── Observable state ──────────────────────────────────────────────────────

  AgentState _state = AgentState.disconnected;
  @override
  AgentState get state => _state;

  String _statusText = 'Disconnected';
  @override
  String get statusText => _statusText;

  final List<AgentMessage> _messages = [];
  @override
  List<AgentMessage> get messages => List.unmodifiable(_messages);

  // ── Streaming state ───────────────────────────────────────────────────────

  String _streamingBuffer = '';
  int? _streamingMsgIndex;

  // ── WebSocket ─────────────────────────────────────────────────────────────

  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  // ── Auto-retry ────────────────────────────────────────────────────────────

  Timer? _retryTimer;
  int _retryAttempt = 0;
  int _retryCountdown = 0;
  @override
  int get retryCountdown => _retryCountdown;
  bool _autoRetry = true;
  @override
  bool get autoRetry => _autoRetry;

  @override
  void setAutoRetry(bool v) {
    _autoRetry = v;
    if (!v) _cancelRetry();
    notifyListeners();
  }

  // ── Interface: Connection ─────────────────────────────────────────────────

  @override
  Future<void> connect({bool fromUser = false}) async {
    if (_state == AgentState.connected || _state == AgentState.connecting) {
      return;
    }
    if (fromUser) {
      _retryAttempt = 0;
      _cancelRetry();
    }
    _setState(AgentState.connecting, 'Connecting...');
    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _sub = _channel!.stream.listen(
        _onMessage,
        onDone: _onDisconnected,
        onError: (_) => _onDisconnected(),
      );
    } catch (_) {
      _setState(AgentState.disconnected, 'Connection failed');
      _scheduleRetry();
    }
  }

  @override
  Future<String?> ping() async {
    try {
      final res = await http
          .get(Uri.parse('$agentUrl/ping'))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return data['model']?.toString() ??
            data['agent']?.toString() ??
            'alive';
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<bool> healthCheck() async {
    try {
      final res = await http
          .get(Uri.parse('$agentUrl/health'))
          .timeout(const Duration(seconds: 2));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── Interface: Messaging ──────────────────────────────────────────────────

  @override
  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    if (_state != AgentState.connected) return;

    final priorHistory = _messages
        .where((m) => m.role == 'user' || m.role == 'agent')
        .map((m) => {
              'role': m.role == 'agent' ? 'assistant' : 'user',
              'content': m.text,
            })
        .toList();
    final trimmed = priorHistory.length > 12
        ? priorHistory.sublist(priorHistory.length - 12)
        : priorHistory;

    _addMessage(AgentMessage(role: 'user', text: text));
    _send({
      'type': 'message',
      'content': text,
      'history': trimmed,
    });
  }

  // ── WebSocket message handling ────────────────────────────────────────────

  void _onMessage(dynamic raw) async {
    final msg = jsonDecode(raw as String);
    final type = msg['type'] as String?;

    switch (type) {
      case 'status':
        final m = (msg['message'] ?? '').toString();
        if (m.startsWith('Agent Ready')) {
          _retryAttempt = 0;
          _cancelRetry();
          _setState(AgentState.connected, 'Full Access · connected');
          await _sendConfig();
        }
        break;

      case 'config_ack':
        _addMessage(AgentMessage(role: 'system', text: msg['message'] ?? ''));
        break;

      case 'thinking':
        _setState(AgentState.thinking, 'Thinking...');
        _streamingBuffer = '';
        _streamingMsgIndex = null;
        break;

      case 'token':
        final t = msg['token']?.toString() ?? '';
        if (t.isEmpty) break;
        _appendStreamingToken(t);
        break;

      case 'tool_call':
        if (_streamingMsgIndex != null) {
          _messages.removeAt(_streamingMsgIndex!);
          _streamingMsgIndex = null;
          _streamingBuffer = '';
        }
        _setState(AgentState.thinking, 'Using tool...');
        _addMessage(AgentMessage(
          role: 'tool_call',
          text: msg['tool'] ?? '',
          meta: {'params': msg['params']?.toString() ?? ''},
        ));
        break;

      case 'tool_result':
        _addMessage(AgentMessage(
            role: 'tool_result', text: msg['result']?.toString() ?? ''));
        break;

      case 'shell_chunk':
        final chunk = msg['chunk']?.toString() ?? '';
        if (chunk.isEmpty) break;
        if (_messages.isNotEmpty && _messages.last.role == 'tool_result') {
          final last = _messages.last;
          _messages[_messages.length - 1] =
              AgentMessage(role: 'tool_result', text: last.text + chunk);
          throttledNotifyListeners();
        } else {
          _addMessage(AgentMessage(role: 'tool_result', text: chunk));
        }
        break;

      case 'reply':
        _setState(AgentState.connected, 'Full Access · connected');
        final replyText = (msg['message'] ?? '').toString();
        if (_streamingMsgIndex != null && _streamingBuffer == replyText) {
          _streamingMsgIndex = null;
          _streamingBuffer = '';
          flushNotifyListeners();
        } else {
          if (_streamingMsgIndex != null) {
            _messages.removeAt(_streamingMsgIndex!);
            _streamingMsgIndex = null;
            _streamingBuffer = '';
          }
          _addMessage(AgentMessage(role: 'agent', text: replyText));
        }
        break;

      case 'error':
        _setState(AgentState.connected, 'Full Access · connected');
        _addMessage(AgentMessage(
            role: 'error', text: msg['message'] ?? 'Unknown error'));
        break;
    }
  }

  void _appendStreamingToken(String token) {
    _streamingBuffer += token;
    if (_streamingMsgIndex == null) {
      _messages.add(AgentMessage(role: 'agent', text: _streamingBuffer));
      _streamingMsgIndex = _messages.length - 1;
    } else {
      _messages[_streamingMsgIndex!] =
          AgentMessage(role: 'agent', text: _streamingBuffer);
    }
    throttledNotifyListeners();
  }

  void _onDisconnected() {
    _sub?.cancel();
    _channel = null;
    _setState(AgentState.disconnected, 'Disconnected');
    _scheduleRetry();
  }

  // ── Retry logic ───────────────────────────────────────────────────────────

  void _scheduleRetry() {
    if (!_autoRetry) return;
    _retryAttempt++;
    final delay =
        [3, 6, 12, 20][_retryAttempt > 4 ? 3 : _retryAttempt - 1];
    _retryCountdown = delay;
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      _retryCountdown--;
      if (_retryCountdown <= 0) {
        t.cancel();
        connect();
      } else {
        notifyListeners();
      }
    });
    notifyListeners();
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryCountdown = 0;
  }

  // ── Configuration ─────────────────────────────────────────────────────────

  Future<void> _sendConfig() async {
    final data = await _settings.load();
    _send({
      'type': 'config',
      'provider': data['provider'],
      'apiKey': data['apiKey'],
      'model': data['model'],
    });
  }

  @override
  Future<void> reloadConfig() async {
    await _sendConfig();
  }

  @override
  void cancelRequest() {
    _send({'type': 'cancel'});
  }

  @override
  void clearMessages() {
    _messages.clear();
    notifyListeners();
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  void _send(Map<String, dynamic> data) {
    _channel?.sink.add(jsonEncode(data));
  }

  void _addMessage(AgentMessage msg) {
    _messages.add(msg);
    flushNotifyListeners();
  }

  void _setState(AgentState s, String text) {
    _state = s;
    _statusText = text;
    flushNotifyListeners();
  }

  @override
  void dispose() {
    _cancelRetry();
    cancelThrottledNotifications();
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
