/// Cloud-mode agent service — direct API calls to AI providers.
///
/// This is a clean, focused implementation that only handles cloud mode.
/// It streams SSE tokens in real-time, supports cancellation, and
/// throttles UI updates for smooth rendering.
///
/// Implements [AgentServiceInterface] so it can be swapped transparently.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../agent_interface.dart';
import '../settings_service.dart';

class CloudAgentService extends ChangeNotifier implements AgentServiceInterface {
  final SettingsService _settings;

  CloudAgentService(this._settings);

  // ── Observable state ──────────────────────────────────────────────────────

  AgentState _state = AgentState.connected;
  @override
  AgentState get state => _state;

  String _statusText = 'Cloud Mode · ready';
  @override
  String get statusText => _statusText;

  final List<AgentMessage> _messages = [];
  @override
  List<AgentMessage> get messages => List.unmodifiable(_messages);

  // ── Streaming state ───────────────────────────────────────────────────────

  String _streamingBuffer = '';
  int? _streamingMsgIndex;

  // ── Throttled notifications ───────────────────────────────────────────────

  Timer? _throttleTimer;
  bool _hasPendingNotification = false;
  static const _throttleDuration = Duration(milliseconds: 50);

  void _throttledNotifyListeners() {
    if (_throttleTimer?.isActive ?? false) {
      _hasPendingNotification = true;
      return;
    }
    notifyListeners();
    _throttleTimer = Timer(_throttleDuration, () {
      if (_hasPendingNotification) {
        _hasPendingNotification = false;
        notifyListeners();
      }
    });
  }

  void _flushNotifyListeners() {
    _throttleTimer?.cancel();
    _hasPendingNotification = false;
    notifyListeners();
  }

  // ── Streaming HTTP ────────────────────────────────────────────────────────

  HttpClient? _streamingClient;
  bool _cancelled = false;

  // ── Interface: Connection ─────────────────────────────────────────────────

  @override
  Future<void> connect({bool fromUser = false}) async {
    // Cloud mode is always "connected" — nothing to connect to.
    _setState(AgentState.connected, 'Cloud Mode · ready');
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
        .map((m) => {
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
          text: 'No API key set. Open Settings and add a key.'));
      return;
    }

    _cancelled = false;
    _setState(AgentState.thinking, 'Thinking...');

    const system =
        'You are Omni-IDE, a friendly AI coding assistant running inside an Android IDE. '
        'You are in Cloud Mode — you do NOT have file system or shell access. '
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
      _setState(AgentState.connected, 'Cloud Mode · ready');
    } catch (e) {
      if (_cancelled) {
        _setState(AgentState.connected, 'Cloud Mode · ready');
        return;
      }
      _addMessage(AgentMessage(role: 'error', text: 'AI Error: $e'));
      _setState(AgentState.connected, 'Cloud Mode · ready');
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

    final request = await client.postUrl(url);
    headers.forEach((k, v) => request.headers.set(k, v));
    request.headers.set('Content-Length', body.length.toString());
    request.write(body);

    final response = await request.close();

    if (response.statusCode != 200) {
      final errBody = await response.transform(const Utf8Decoder()).join();
      client.close();
      String errMsg = 'HTTP ${response.statusCode}';
      try {
        final j = jsonDecode(errBody) as Map<String, dynamic>;
        errMsg = j['error']?['message'] ?? errMsg;
      } catch {}
      throw Exception(errMsg);
    }

    String assembled = '';
    String buffer = '';

    await for (final chunk in response.transform(const Utf8Decoder())) {
      if (_cancelled) {
        client.close();
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
          } catch {}
        }
      }
    }

    client.close();
    _streamingClient = null;

    if (_streamingMsgIndex != null) {
      _streamingMsgIndex = null;
      _streamingBuffer = '';
      _flushNotifyListeners();
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
    _throttledNotifyListeners();
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
    _setState(AgentState.connected, 'Cloud Mode · ready');
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
    _flushNotifyListeners();
  }

  void _setState(AgentState s, String text) {
    _state = s;
    _statusText = text;
    _flushNotifyListeners();
  }

  @override
  void dispose() {
    _throttleTimer?.cancel();
    _streamingClient?.close(force: true);
    super.dispose();
  }
}
