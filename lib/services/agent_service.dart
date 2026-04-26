import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'settings_service.dart';

enum AgentState { disconnected, connecting, connected, thinking }

class AgentMessage {
  final String role; // user | agent | system | tool_call | tool_result | error
  final String text;
  final Map<String, dynamic>? meta;
  final DateTime time;

  AgentMessage({
    required this.role,
    required this.text,
    this.meta,
  }) : time = DateTime.now();
}

class AgentService extends ChangeNotifier {
  static const startCommand = '~/omni-ide/start_agent.sh';
  static const agentUrl = 'http://localhost:8080';

  final _settings = SettingsService();

  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  AgentState _state = AgentState.disconnected;
  AgentState get state => _state;

  final List<AgentMessage> _messages = [];
  List<AgentMessage> get messages => List.unmodifiable(_messages);

  String _statusText = 'Disconnected';
  String get statusText => _statusText;

  // Auto-retry
  Timer? _retryTimer;
  int _retryAttempt = 0;
  int _retryCountdown = 0;
  int get retryCountdown => _retryCountdown;
  bool _autoRetry = true;
  bool get autoRetry => _autoRetry;

  // ── Connect ──────────────────────────────────
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
      _channel = WebSocketChannel.connect(Uri.parse('ws://localhost:8080'));
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

  /// Probe the agent HTTP /ping endpoint without opening a WebSocket.
  /// Returns the model string on success, or null on failure.
  Future<String?> ping() async {
    try {
      final res = await http
          .get(Uri.parse('$agentUrl/ping'))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return data['model']?.toString() ?? data['agent']?.toString() ?? 'alive';
      }
    } catch (_) {}
    return null;
  }

  void setAutoRetry(bool v) {
    _autoRetry = v;
    if (!v) _cancelRetry();
    notifyListeners();
  }

  void _onMessage(dynamic raw) async {
    final msg = jsonDecode(raw as String);
    final type = msg['type'] as String?;

    switch (type) {
      case 'status':
        if (msg['message'] == 'Agent Ready') {
          _retryAttempt = 0;
          _cancelRetry();
          _setState(AgentState.connected, 'Connected');
          await _sendConfig();
        }
        break;
      case 'config_ack':
        _addMessage(AgentMessage(role: 'system', text: msg['message'] ?? ''));
        break;
      case 'thinking':
        _setState(AgentState.thinking, 'Thinking...');
        break;
      case 'tool_call':
        _setState(AgentState.thinking, 'Using tool...');
        _addMessage(AgentMessage(
          role: 'tool_call',
          text: msg['tool'] ?? '',
          meta: {'params': msg['params']?.toString() ?? ''},
        ));
        break;
      case 'tool_result':
        _addMessage(AgentMessage(
          role: 'tool_result',
          text: msg['result']?.toString() ?? '',
        ));
        break;
      case 'reply':
        _setState(AgentState.connected, 'Connected');
        _addMessage(AgentMessage(role: 'agent', text: msg['message'] ?? ''));
        break;
      case 'error':
        _setState(AgentState.connected, 'Connected');
        _addMessage(AgentMessage(
          role: 'error',
          text: msg['message'] ?? 'Unknown error',
        ));
        break;
    }
  }

  void _onDisconnected() {
    _sub?.cancel();
    _channel = null;
    _setState(AgentState.disconnected, 'Disconnected');
    _scheduleRetry();
  }

  // ── Retry with backoff ─────────────────────────
  void _scheduleRetry() {
    if (!_autoRetry) return;
    _retryAttempt++;
    // 3s, 6s, 12s, then capped at 20s
    final delay = [3, 6, 12, 20][
        _retryAttempt > 4 ? 3 : _retryAttempt - 1];
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

  Future<void> _sendConfig() async {
    final data = await _settings.load();
    _send({
      'type': 'config',
      'provider': data['provider'],
      'apiKey': data['apiKey'],
      'model': data['model'],
    });
  }

  // ── Send Message ─────────────────────────────
  void sendMessage(String text) {
    if (_state != AgentState.connected) return;
    if (text.trim().isEmpty) return;

    final history = _messages
        .where((m) => m.role == 'user' || m.role == 'agent')
        .map((m) => {
              'role': m.role == 'agent' ? 'assistant' : 'user',
              'content': m.text,
            })
        .toList();

    _addMessage(AgentMessage(role: 'user', text: text));

    _send({
      'type': 'message',
      'content': text,
      'history':
          history.length > 12 ? history.sublist(history.length - 12) : history,
    });
  }

  // ── Helpers ──────────────────────────────────
  void _send(Map<String, dynamic> data) {
    _channel?.sink.add(jsonEncode(data));
  }

  void _addMessage(AgentMessage msg) {
    _messages.add(msg);
    notifyListeners();
  }

  void _setState(AgentState s, String text) {
    _state = s;
    _statusText = text;
    notifyListeners();
  }

  void clearMessages() {
    _messages.clear();
    notifyListeners();
  }

  Future<void> reloadConfig() => _sendConfig();

  @override
  void dispose() {
    _cancelRetry();
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
