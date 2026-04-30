/// Cloud-mode agent service — direct API calls to AI providers.
///
/// This service works without any local agent or Termux. It calls
/// AI providers directly over HTTPS using SSE streaming.
///
/// Connection flow:
///   1. Call [connect()] → state becomes `connected` immediately
///   2. User sends message → [sendMessage] calls the provider API
///   3. Streaming tokens are displayed in real-time
///   4. Errors are caught and shown as friendly messages

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../agent_interface.dart';
import '../settings_service.dart';
import 'throttled_notifications.dart';

class CloudAgentService extends ChangeNotifier
    with ThrottledNotifications
    implements AgentServiceInterface {
  final SettingsService _settings;

  CloudAgentService(this._settings);

  // ── Observable state ──────────────────────────────────────────────────────

  AgentState _state = AgentState.connected;
  @override
  AgentState get state => _state;

  String _statusText = 'Cloud Mode \u00b7 ready';
  @override
  String get statusText => _statusText;

  final List<AgentMessage> _messages = [];
  @override
  List<AgentMessage> get messages => List.unmodifiable(_messages);

  // ── Streaming state ───────────────────────────────────────────────────────

  String _streamingBuffer = '';
  int? _streamingMsgIndex;

  // ── Streaming HTTP ────────────────────────────────────────────────────────

  HttpClient? _streamingClient;
  bool _cancelled = false;

  // ── Interface: Connection ─────────────────────────────────────────────────

  @override
  Future<void> connect({bool fromUser = false}) async {
    // Cloud mode is always "connected" — nothing to connect to.
    // Just set the state and notify listeners.
    // Always reset to connected state even if called multiple times.
    _state = AgentState.connected;
    _statusText = 'Cloud Mode \u00b7 ready';
    flushNotifyListeners();
  }

  @override
  Future<String?> ping() async => 'cloud';

  @override
  Future<bool> healthCheck() async => true;

  // ── Interface: Messaging ──────────────────────────────────────────────────

  @override
  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    final priorHistory = _messages
        .where((m) => m.role == 'user' || m.role == 'agent')
        .map((m) => <String, String>{
              'role': m.role == 'agent' ? 'assistant' : 'user',
              'content': m.text,
            })
        .toList();
    final trimmed = priorHistory.length > 12
        ? priorHistory.sublist(priorHistory.length - 12)
        : priorHistory;

    _addMessage(AgentMessage(role: 'user', text: text));
    await _sendCloudStream(text, trimmed);
  }

  Future<void> _sendCloudStream(
      String userText, List<Map<String, String>> priorHistory) async {
    final cfg = await _settings.load();
    final provider = cfg['provider']!;
    final apiKey = cfg['apiKey']!;
    final model = cfg['model']!;

    if (apiKey.isEmpty) {
      _addMessage(AgentMessage(
          role: 'error',
          text: 'No API key configured. Tap Settings to add your key.'));
      return;
    }

    if (model.isEmpty) {
      _addMessage(AgentMessage(
          role: 'error',
          text: 'No model selected. Tap Settings to choose a model.'));
      return;
    }

    _cancelled = false;
    _setState(AgentState.thinking, 'Thinking...');

    const system =
        'You are Omni-IDE, a friendly AI coding assistant running inside an Android IDE. '
        'You are in Cloud Mode — you do NOT have file system or shell access. '
        'You cannot read, write, or modify files, and you cannot execute shell commands. '
        'If the user asks you to perform file operations or run commands, explain that '
        'these features require Local Mode (Termux). You can still help with code '
        'questions, explanations, and writing code snippets. '
        'Write clear, idiomatic code in fenced blocks and keep replies focused.';

    final messages = [
      ...priorHistory,
      {'role': 'user', 'content': userText},
    ];

    try {
      await _streamSSE(
        provider: provider,
        apiKey: apiKey,
        model: model,
        system: system,
        messages: messages,
      );
      _setState(AgentState.connected, 'Cloud Mode \u00b7 ready');
    } catch (e) {
      if (_cancelled) {
        _setState(AgentState.connected, 'Cloud Mode \u00b7 ready');
        return;
      }
      final msg = _friendlyError(e.toString());
      _addMessage(AgentMessage(role: 'error', text: msg));
      _setState(AgentState.connected, 'Cloud Mode \u00b7 ready');
    }
  }

  Future<void> _streamSSE({
    required String provider,
    required String apiKey,
    required String model,
    required String system,
    required List<Map<String, String>> messages,
  }) async {
    late Uri url;
    Map<String, String> headers;
    String body;

    if (provider == 'anthropic') {
      url = Uri.parse('https://api.anthropic.com/v1/messages');
      headers = {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
        'accept': 'text/event-stream',
      };
      body = jsonEncode({
        'model': model,
        'max_tokens': 2048,
        'system': system,
        'messages': messages,
        'stream': true,
      });
    } else {
      final base = provider == 'openai'
          ? 'https://api.openai.com/v1'
          : 'https://openrouter.ai/api/v1';
      url = Uri.parse('$base/chat/completions');
      headers = {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
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
        'stream': true,
      });
    }

    final client = HttpClient();
    _streamingClient = client;

    final bodyBytes = utf8.encode(body);
    final request = await client.postUrl(url);
    headers.forEach((k, v) => request.headers.set(k, v));
    request.headers.set('Content-Length', bodyBytes.length.toString());
    request.add(bodyBytes);

    final response = await request.close();

    if (response.statusCode != 200) {
      final errBody = await response.transform(const Utf8Decoder()).join();
      client.close();
      _streamingClient = null;
      throw Exception(_parseHttpError(response.statusCode, errBody));
    }

    String assembled = '';
    String buffer = '';

    await for (final chunk in response.transform(const Utf8Decoder())) {
      if (_cancelled) {
        client.close();
        _streamingClient = null;
        return;
      }

      buffer += chunk;
      int idx;
      while ((idx = buffer.indexOf('\n\n')) >= 0) {
        final event = buffer.substring(0, idx);
        buffer = buffer.substring(idx + 2);

        for (final line in event.split('\n')) {
          final trimmed = line.trim();
          if (!trimmed.startsWith('data:')) continue;
          final data = trimmed.substring(5).trim();
          if (data.isEmpty || data == '[DONE]') continue;

          try {
            final evt = jsonDecode(data) as Map<String, dynamic>;
            String delta = '';

            if (provider == 'anthropic') {
              if (evt['type'] == 'content_block_delta') {
                delta = (evt['delta'] as Map?)?['text']?.toString() ?? '';
              }
            } else {
              final choices = evt['choices'] as List?;
              if (choices != null && choices.isNotEmpty) {
                delta = (((choices[0] as Map?)?['delta'] as Map?)?['content']
                        ?.toString() ??
                    '');
              }
            }

            if (delta.isNotEmpty) {
              assembled += delta;
              _appendStreamingToken(delta);
            }
          } catch (e) {
            // Ignore malformed SSE data chunks — these are expected
            // from time to time with streaming responses
            debugPrint('[CloudAgent] Malformed SSE chunk: $e');
          }
        }
      }
    }

    client.close();
    _streamingClient = null;

    if (_streamingMsgIndex != null) {
      _streamingMsgIndex = null;
      _streamingBuffer = '';
      flushNotifyListeners();
    } else if (assembled.isNotEmpty) {
      _addMessage(AgentMessage(role: 'agent', text: assembled));
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

  // ── Interface: Configuration ──────────────────────────────────────────────

  @override
  void clearMessages() {
    _messages.clear();
    notifyListeners();
  }

  @override
  Future<void> reloadConfig() async {
    // Cloud mode reads settings on every call — no-op.
  }

  @override
  void cancelRequest() {
    _cancelled = true;
    _streamingClient?.close(force: true);
    _streamingClient = null;
    if (_streamingMsgIndex != null) {
      _streamingMsgIndex = null;
      _streamingBuffer = '';
    }
    _setState(AgentState.connected, 'Cloud Mode \u00b7 ready');
  }

  // ── Interface: Retry (not applicable in cloud mode) ───────────────────────

  @override
  bool get autoRetry => false;

  @override
  int get retryCountdown => 0;

  @override
  void setAutoRetry(bool value) {
    // No-op in cloud mode
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  void _addMessage(AgentMessage msg) {
    _messages.add(msg);
    flushNotifyListeners();
  }

  void _setState(AgentState s, String text) {
    _state = s;
    _statusText = text;
    flushNotifyListeners();
  }

  /// Convert raw error strings into user-friendly messages.
  String _friendlyError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('socketexception') ||
        lower.contains('connection refused') ||
        lower.contains('connection failed')) {
      return 'No internet connection. Check your network and try again.';
    }
    if (lower.contains('handshake') || lower.contains('certificate')) {
      return 'Secure connection failed. Try again in a moment.';
    }
    if (lower.contains('timeout')) {
      return 'Request timed out. The AI provider may be busy — try again.';
    }
    // Strip the "Exception: " prefix for cleaner messages
    return raw.replaceAll('Exception: ', '');
  }

  /// Parse HTTP error responses into readable messages.
  String _parseHttpError(int status, String body) {
    try {
      final j = jsonDecode(body) as Map<String, dynamic>;
      final msg = j['error']?['message']?.toString();
      if (msg != null && msg.isNotEmpty) {
        // Shorten very long error messages
        if (msg.length > 200) return '${msg.substring(0, 197)}...';
        return msg;
      }
    } catch (e) {
      // Not JSON — fall through
      debugPrint('[CloudAgent] Non-JSON error response: $e');
    }
    switch (status) {
      case 401:
        return 'Invalid API key. Check your key in Settings.';
      case 403:
        return 'Access denied. Your key may not have access to this model.';
      case 404:
        return 'Model not found. Pick a different model in Settings.';
      case 429:
        return 'Rate limited — too many requests. Wait a moment and try again.';
      case 500:
      case 502:
      case 503:
        return 'The AI provider is experiencing issues. Try again in a moment.';
      default:
        return 'Request failed ($status). Check your settings and try again.';
    }
  }

  @override
  void dispose() {
    cancelThrottledNotifications();
    _streamingClient?.close(force: true);
    super.dispose();
  }
}
