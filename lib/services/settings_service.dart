import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const _kProvider = 'provider';
  static const _kKey = 'api_key';
  static const _kModel = 'model';

  static const providers = {
    'openrouter': 'OpenRouter',
    'anthropic': 'Claude (Anthropic)',
    'openai': 'OpenAI',
    'custom': 'Custom API',
  };

  static const baseUrls = {
    'openrouter': 'https://openrouter.ai/api/v1',
    'anthropic': 'https://api.anthropic.com',
    'openai': 'https://api.openai.com/v1',
  };

  Future<Map<String, String>> load() async {
    final p = await SharedPreferences.getInstance();
    return {
      'provider': p.getString(_kProvider) ?? 'openrouter',
      'apiKey': p.getString(_kKey) ?? '',
      'model': p.getString(_kModel) ?? 'anthropic/claude-3.5-sonnet',
    };
  }

  Future<void> save({
    required String provider,
    required String apiKey,
    required String model,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kProvider, provider);
    await p.setString(_kKey, apiKey);
    await p.setString(_kModel, model);
  }

  Future<bool> hasKey() async {
    final d = await load();
    return d['apiKey']!.isNotEmpty;
  }
}
