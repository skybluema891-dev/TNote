import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/document.dart';
import 'export_service.dart';

class ShareService {
  ShareService(this._export);
  final ExportService _export;

  Future<void> share(
    NoteDocument document, {
    required bool all,
    required bool markdown,
    required RenderBox? source,
  }) async {
    final extension = markdown ? 'md' : 'txt';
    final directory = await getTemporaryDirectory();
    final base = _safeName(all ? document.name : document.activeTab.name);
    final file = File(p.join(directory.path, '$base.$extension'));
    if (all) {
      await _export.exportAll(document, file.path, markdown: markdown);
    } else {
      await _export.exportTab(
        document.activeTab,
        file.path,
        markdown: markdown,
      );
    }
    final origin = source == null
        ? null
        : source.localToGlobal(Offset.zero) & source.size;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        fileNameOverrides: [p.basename(file.path)],
        title: 'TNoteから共有',
        sharePositionOrigin: origin,
      ),
    );
  }

  String _safeName(String name) {
    final withoutExtension = p.basenameWithoutExtension(name);
    final cleaned = withoutExtension
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    return cleaned.isEmpty ? 'TNote' : cleaned;
  }
}
