import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CollaborationKeys {
  const CollaborationKeys();

  static const _storage = FlutterSecureStorage();
  static const _mac = MethodChannel('com.tnote.app/collaboration-keys');
  static const _windows = MethodChannel('tnote/windows_installation');

  Future<String> openEnrollment(File receipt, String room) async {
    if (!Platform.isWindows ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(room) ||
        await receipt.length() > 8192) {
      throw const FormatException('この参加情報を使用できません。');
    }
    final data = jsonDecode(await receipt.readAsString());
    if (data is! Map ||
        data['format'] != 'TNote migration key v1' ||
        data['room'] != room ||
        data['protected'] is! String) {
      throw const FormatException('この共同メモに対応する参加情報を選んでください。');
    }
    final bytes = await _windows.invokeMethod<Uint8List>(
      'openMigrationEnrollment',
      [room, base64Decode(data['protected'] as String)],
    );
    if (bytes == null) throw const FormatException('参加情報を読み取れません。');
    // A platform-channel response may be backed by read-only engine memory.
    final key = Uint8List.fromList(bytes);
    try {
      if (key.length != 32 ||
          sha256.convert([...utf8.encode('TNote room 1'), ...key]).toString() !=
              room) {
        throw const FormatException('共同メモと参加情報が一致しません。');
      }
      return base64UrlEncode(key);
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  Future<String?> read({required String key, bool requestAccess = false}) =>
      Platform.isMacOS
      ? _mac.invokeMethod<String>('read', {
          'key': key,
          'requestAccess': requestAccess,
        })
      : _storage.read(key: key);

  Future<void> write({required String key, required String value}) =>
      Platform.isMacOS
      ? _mac.invokeMethod<void>('write', {'key': key, 'value': value})
      : _storage.write(key: key, value: value);
}
