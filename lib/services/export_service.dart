import 'dart:io';

import '../models/document.dart';

class ExportService {
  Future<void> exportTab(
    NoteTab tab,
    String path, {
    required bool markdown,
  }) async {
    final contents = markdown ? '# ${tab.name}\n\n${tab.text}' : tab.text;
    await File(path).writeAsString(contents, flush: true);
  }

  Future<void> exportAll(
    NoteDocument document,
    String path, {
    required bool markdown,
  }) async {
    final separator = markdown ? '\n\n---\n\n' : '\n\n====================\n\n';
    final contents = document.tabs
        .map((tab) {
          return markdown
              ? '# ${tab.name}\n\n${tab.text}'
              : '${tab.name}\n\n${tab.text}';
        })
        .join(separator);
    await File(path).writeAsString(contents, flush: true);
  }
}
