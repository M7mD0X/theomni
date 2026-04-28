import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SettingsService {
  static const _kProvider = 'provider';
  static const _kKey = 'api_key';
  static const _kModel = 'model';

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

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
    return {
      'provider': await _storage.read(key: _kProvider) ?? 'openrouter',
      'apiKey': await _storage.read(key: _kKey) ?? '',
      'model': await _storage.read(key: _kModel) ?? 'anthropic/claude-3.5-sonnet',
    };
  }

  Future<void> save({
    required String provider,
    required String apiKey,
    required String model,
  }) async {
    await _storage.write(key: _kProvider, value: provider);
    await _storage.write(key: _kKey, value: apiKey);
    await _storage.write(key: _kModel, value: model);
  }

  Future<bool> hasKey() async {
    final d = await load();
    return d['apiKey']!.isNotEmpty;
  }

  /// Delete all stored settings — useful for sign-out / factory reset.
  Future<void> clearAll() async {
    await _storage.delete(key: _kProvider);
    await _storage.delete(key: _kKey);
    await _storage.delete(key: _kModel);
  }
}
