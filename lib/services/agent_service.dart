import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'app_mode_service.dart';
import 'settings_service.dart';

enum AgentState { disconnected, connecting, connected, thinking }

class AgentMessage {
  final String role; // user | agent | system | tool_call | tool_result | error
  final String text;
  final Map<String, dynamic>? meta;
  final DateTime time;

  AgentMessage({required this.role, required this.text, this.meta})
      : time = DateTime.now();
}

/// Dual-mode agent.
///
///   • Cloud mode: send `messages` directly to the configured AI provider over
///     HTTPS. No tools, just chat. Always "connected" once a key is set.
///
///   • Local mode: existing WebSocket protocol against ws://localhost:8080.
class AgentService extends ChangeNotifier {
  static const startCommand = '~/omni-ide/start_agent.sh';
  static const agentUrl = 'http://localhost:8080';

  final _settings = SettingsService();
  final AppModeService modeService;

  AgentService(this.modeService) {
    modeService.addListener(_onModeChanged);
  }

  // ── State ───────────────────────────────────────────
  AgentState _state = AgentState.disconnected;
  AgentState get state => _state;

  String _statusText = 'Disconnected';
  String get statusText => _statusText;

  final List<AgentMessage> _messages = [];
  List<AgentMessage> get messages => List.unmodifiable(_messages);

  AppMode get mode => modeService.mode;

  // Streaming buffer for live token reveal
  String _streamingBuffer = '';
  int? _streamingMsgIndex;

  // Local-mode WebSocket
  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  // Auto-retry (local mode only)
  Timer? _retryTimer;
  int _retryAttempt = 0;
  int _retryCountdown = 0;
  int get retryCountdown => _retryCountdown;
  bool _autoRetry = true;
  bool get autoRetry => _autoRetry;

  void _onModeChanged() {
    // Tear down WS if user switched to cloud, or kick off connection on local.
    if (modeService.mode == AppMode.cloud) {
      _sub?.cancel();
      _channel?.sink.close();
      _channel = null;
      _cancelRetry();
      _enterCloudReady();
    } else {
      connect();
    }
  }

  // ── Public API ──────────────────────────────────────
  Future<void> connect({bool fromUser = false}) async {
    if (modeService.mode == AppMode.cloud) {
      _enterCloudReady();
      return;
    }
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

  void setAutoRetry(bool v) {
    _autoRetry = v;
    if (!v) _cancelRetry();
    notifyListeners();
  }

  // ── Sending ─────────────────────────────────────────
  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    // Snapshot history BEFORE the new user turn is appended.
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

    if (modeService.mode == AppMode.cloud) {
      await _sendCloud(text, trimmed);
    } else {
      _sendLocal(text, trimmed);
    }
  }

  Future<void> _sendCloud(
      String userText, List<Map<String, String>> priorHistory) async {
    final cfg = await _settings.load();
    final provider = cfg['provider']!;
    final apiKey = cfg['apiKey']!;
    final model = cfg['model']!;

    if (apiKey.isEmpty) {
      _addMessage(AgentMessage(
          role: 'error',
          text: 'No API key set. Open Settings and add a key.'));
      return;
    }

    _setState(AgentState.thinking, 'Thinking...');
    try {
      final reply = await _callProvider(
        provider: provider,
        apiKey: apiKey,
        model: model,
        messages: [
          ...priorHistory,
          {'role': 'user', 'content': userText},
        ],
      );
      _addMessage(AgentMessage(role: 'agent', text: reply));
      _setState(AgentState.connected, 'Cloud Mode · ready');
    } catch (e) {
      _addMessage(AgentMessage(role: 'error', text: 'AI Error: $e'));
      _setState(AgentState.connected, 'Cloud Mode · ready');
    }
  }

  Future<String> _callProvider({
    required String provider,
    required String apiKey,
    required String model,
    required List<Map<String, String>> messages,
  }) async {
    const system =
        'You are Omni-IDE, a friendly AI coding assistant running inside an Android IDE. '
        'You are in Cloud Mode — you do NOT have file system or shell access. '
        'Write clear, idiomatic code in fenced blocks and keep replies focused.';

    Uri url;
    Map<String, String> headers;
    String body;

    if (provider == 'anthropic') {
      url = Uri.parse('https://api.anthropic.com/v1/messages');
      headers = {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      };
      body = jsonEncode({
        'model': model,
        'max_tokens': 2048,
        'system': system,
        'messages': messages,
      });
    } else {
      // OpenAI / OpenRouter / Custom (OpenAI-compatible)
      final base = provider == 'openai'
          ? 'https://api.openai.com/v1'
          : 'https://openrouter.ai/api/v1';
      url = Uri.parse('$base/chat/completions');
      headers = {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
        if (provider == 'openrouter') 'HTTP-Referer': 'https://omni-ide.app',
        if (provider == 'openrouter') 'X-Title': 'Omni-IDE',
      };
      body = jsonEncode({
        'model': model,
        'max_tokens': 2048,
        'messages': [
          {'role': 'system', 'content': system},
          ...messages,
        ],
      });
    }

    final res = await http
        .post(url, headers: headers, body: body)
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) {
      Map<String, dynamic>? j;
      try { j = jsonDecode(res.body) as Map<String, dynamic>; } catch (_) {}
      throw Exception(j?['error']?['message'] ?? 'HTTP ${res.statusCode}');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (provider == 'anthropic') {
      final content = j['content'] as List?;
      return (content != null && content.isNotEmpty)
          ? (content.first['text']?.toString() ?? '')
          : '';
    }
    final choices = j['choices'] as List?;
    return (choices != null && choices.isNotEmpty)
        ? (choices.first['message']?['content']?.toString() ?? '')
        : '';
  }

  void _sendLocal(String text, List<Map<String, String>> priorHistory) {
    if (_state != AgentState.connected) return;
    _send({
      'type': 'message',
      'content': text,
      'history': priorHistory,
    });
  }

  // ── Local WS handlers ───────────────────────────────
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
        // Streaming token from the AI provider — append to a live "agent" bubble.
        final t = msg['token']?.toString() ?? '';
        if (t.isEmpty) break;
        _streamingBuffer += t;
        if (_streamingMsgIndex == null) {
          _messages.add(AgentMessage(role: 'agent', text: _streamingBuffer));
          _streamingMsgIndex = _messages.length - 1;
        } else {
          _messages[_streamingMsgIndex!] =
              AgentMessage(role: 'agent', text: _streamingBuffer);
        }
        notifyListeners();
        break;
      case 'tool_call':
        // A tool call ends streaming — drop the in-progress agent bubble (it was JSON).
        if (_streamingMsgIndex != null) {
          _messages.removeAt(_streamingMsgIndex!);
          _streamingMsgIndex = null;
          _streamingBuffer = '';
        }
        _setState(AgentState.thinking, 'Using tool…');
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
        // Live stdout from run_shell — surface as an incremental tool-result line.
        final chunk = msg['chunk']?.toString() ?? '';
        if (chunk.isEmpty) break;
        if (_messages.isNotEmpty && _messages.last.role == 'tool_result') {
          final last = _messages.last;
          _messages[_messages.length - 1] =
              AgentMessage(role: 'tool_result', text: last.text + chunk);
          notifyListeners();
        } else {
          _addMessage(AgentMessage(role: 'tool_result', text: chunk));
        }
        break;
      case 'reply':
        _setState(AgentState.connected, 'Full Access · connected');
        // If we already streamed the same content into a live bubble, just finalise it.
        final replyText = (msg['message'] ?? '').toString();
        if (_streamingMsgIndex != null && _streamingBuffer == replyText) {
          _streamingMsgIndex = null;
          _streamingBuffer = '';
          notifyListeners();
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

  void _onDisconnected() {
    _sub?.cancel();
    _channel = null;
    if (modeService.mode == AppMode.local) {
      _setState(AgentState.disconnected, 'Disconnected');
      _scheduleRetry();
    } else {
      _enterCloudReady();
    }
  }

  void _scheduleRetry() {
    if (!_autoRetry) return;
    if (modeService.mode != AppMode.local) return;
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

  Future<void> _sendConfig() async {
    final data = await _settings.load();
    _send({
      'type': 'config',
      'provider': data['provider'],
      'apiKey': data['apiKey'],
      'model': data['model'],
    });
  }

  void _enterCloudReady() {
    _cancelRetry();
    _setState(AgentState.connected, 'Cloud Mode · ready');
  }

  // ── Helpers ─────────────────────────────────────────
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

  Future<void> reloadConfig() async {
    if (modeService.mode == AppMode.local) {
      await _sendConfig();
    }
  }

  @override
  void dispose() {
    modeService.removeListener(_onModeChanged);
    _cancelRetry();
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
