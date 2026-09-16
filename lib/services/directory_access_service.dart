import 'dart:io';

import 'package:flutter/services.dart';

/// Native sandbox permissions stay here; other platforms keep their picker flow.
class DirectoryAccessService {
  static const _channel = MethodChannel('com.tnote.app/directory-access');

  Future<void> restore() async {
    if (Platform.isMacOS) await _channel.invokeMethod<void>('restore');
  }

  Future<String?> lastDirectory() async {
    if (!Platform.isMacOS) return null;
    return _channel.invokeMethod<String>('lastDirectory');
  }

  Future<bool> ensureForFile(String path) async {
    if (!Platform.isMacOS) return true;
    return await _channel.invokeMethod<bool>('ensureForFile', path) ?? false;
  }
}
