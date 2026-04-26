import 'package:flutter/services.dart';

/// Thin wrapper around the `com.omniide/native` MethodChannel that performs
/// file-system operations directly through Kotlin — used by the file
/// explorer when the local agent is not running. Works even when the
/// device is offline and Termux isn't installed.
class NativeFileService {
  static const _channel = MethodChannel('com.omniide/native');

  /// Returns a list of `{name, path, isDir, size, mtime}` maps for [path].
  static Future<List<Map<String, dynamic>>> listDir(String path) async {
    final raw = await _channel.invokeMethod<List<dynamic>>(
      'listDir',
      {'path': path},
    );
    if (raw == null) return [];
    return raw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  /// Returns `{content, absPath, size}` or `{error}`.
  static Future<Map<String, dynamic>> readFile(String path) async {
    final raw = await _channel.invokeMethod<Map>('readFile', {'path': path});
    if (raw == null) return {'error': 'channel error'};
    return Map<String, dynamic>.from(raw);
  }

  static Future<bool> writeFile(String path, String content) async =>
      await _channel.invokeMethod<bool>(
          'writeFile', {'path': path, 'content': content}) ??
      false;

  static Future<bool> mkdir(String path) async =>
      await _channel.invokeMethod<bool>('mkdir', {'path': path}) ?? false;

  static Future<bool> deletePath(String path) async =>
      await _channel.invokeMethod<bool>('deletePath', {'path': path}) ?? false;

  static Future<bool> rename(String from, String to) async =>
      await _channel.invokeMethod<bool>(
          'renamePath', {'from': from, 'to': to}) ??
      false;
}
