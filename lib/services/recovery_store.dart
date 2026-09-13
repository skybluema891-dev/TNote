import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/document.dart';

class RecoveryStore {
  RecoveryStore(this.directory);
  final Directory directory;
  final List<String> warnings = [];
  Future<List<NoteDocument>> load() async {
    await directory.create(recursive: true);
    final documents = <NoteDocument>[];
    await for (final entry in directory.list()) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      try {
        final doc = NoteDocument.fromJson(
          jsonDecode(await entry.readAsString()) as Map<String, dynamic>,
        );
        if (doc.tabs.isEmpty || !doc.tabs.any((t) => t.id == doc.activeTabId)) {
          throw const FormatException('復旧データのタブが不正です');
        }
        doc.savedRevision = -1;
        documents.add(doc);
      } catch (_) {
        warnings.add('読み込めない復旧ファイルを保持しました: ${entry.path}');
      }
    }
    return documents;
  }

  String _path(NoteDocument doc) =>
      p.join(directory.path, '${p.basename(doc.id)}.json');
  Future<void> write(NoteDocument doc) async {
    await directory.create(recursive: true);
    final data = jsonEncode(doc.toJson());
    final target = _path(doc);
    final temp = File('$target.tmp');
    await temp.writeAsString(data, flush: true);
    await temp.rename(target);
  }

  Future<void> remove(NoteDocument doc) async {
    final file = File(_path(doc));
    if (await file.exists()) await file.delete();
  }
}
