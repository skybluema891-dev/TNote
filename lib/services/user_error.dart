import 'dart:io';

import 'package:flutter/services.dart';

import 'document_store.dart';
import 'file_lock_service.dart';

/// Internal exception prefixes and operating-system messages are not UI text.
String userError(Object error) {
  if (error is DocumentConflict || error is FileAlreadyOpen) {
    return error.toString();
  }
  final String? message = switch (error) {
    FileSystemException e => e.message,
    FormatException e => e.message,
    StateError e => e.message,
    UnsupportedError e => e.message,
    PlatformException e => e.message,
    _ => null,
  };
  if (message != null &&
      RegExp(r'[ぁ-んァ-ヶ一-龯]').hasMatch(message) &&
      !RegExp(r'[A-Za-z]{4,}').hasMatch(message.replaceAll('tnote', ''))) {
    return message;
  }
  if (error is FileSystemException) {
    return 'ファイルを読み書きできませんでした。保存先の接続、空き容量、アクセス権を確認して、もう一度お試しください。';
  }
  if (error is FormatException) {
    return '文書を読み込めませんでした。対応する文書形式か、ファイルが破損していないか確認してください。';
  }
  if (error is PlatformException) {
    return '操作を完了できませんでした。保存先や設定を確認し、もう一度お試しください。';
  }
  return '処理を完了できませんでした。未保存の文書は別の名前で保存し、もう一度お試しください。';
}
