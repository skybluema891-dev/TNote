import 'dart:io';

import 'package:flutter/services.dart';

import 'document_controller.dart';

class PlatformDocumentService {
  static const _channel = MethodChannel('com.tnote.app/documents');
  static DocumentController? _controller;

  static Future<void> prepareToTerminate() async {
    if (Platform.isMacOS) {
      await _channel.invokeMethod<void>('prepareToTerminate');
    }
  }

  /// Finder can deliver documents before Dart and the workspace are ready.
  static Future<void> notifyReady() async {
    if (Platform.isMacOS) {
      await _channel.invokeMethod<void>('documentsReady');
    }
    if (Platform.isIOS) {
      await _channel.invokeMethod<void>('documentsReady');
      await _consumeSharedText();
    }
  }

  static void bind(DocumentController controller) {
    _controller = controller;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openDocuments') {
        final paths =
            (call.arguments as List?)?.whereType<String>() ?? const <String>[];
        for (final path in paths) {
          final request = controller.openRequest;
          if (request != null) {
            await request(path);
          } else {
            controller.startupPath = path;
          }
        }
        return;
      }
      if (call.method == 'sharedTextAvailable') await _consumeSharedText();
    });
  }

  static Future<void> _consumeSharedText() async {
    final controller = _controller;
    if (controller == null || !Platform.isIOS) return;
    final queued = await _channel.invokeListMethod<dynamic>(
      'consumeSharedText',
    );
    for (final raw in queued ?? const <dynamic>[]) {
      if (raw is! Map) continue;
      final id = raw['id'] as String?;
      final text = raw['text'] as String?;
      if (id == null || text == null) continue;
      await controller.importSharedText(
        id: id,
        text: text,
        suggestedName: raw['suggestedName'] as String?,
      );
      await _channel.invokeMethod<void>('acknowledgeSharedText', id);
    }
  }
}
