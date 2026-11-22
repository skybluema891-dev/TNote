import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CollaborationKeys {
  const CollaborationKeys();

  static const _storage = FlutterSecureStorage();
  static const _mac = MethodChannel('com.tnote.app/collaboration-keys');

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
