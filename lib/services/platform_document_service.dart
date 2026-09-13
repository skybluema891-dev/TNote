import 'package:flutter/services.dart';

import 'document_controller.dart';

class PlatformDocumentService {
  static const _channel = MethodChannel('com.tnote.app/documents');

  static void bind(DocumentController controller) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'openDocuments') return;
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
    });
  }
}
