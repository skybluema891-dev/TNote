import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class BackupEntry {
  const BackupEntry(this.path, this.createdAt);
  final String path;
  final DateTime createdAt;
}

class BackupService {
  BackupService(this.root);
  final Directory root;

  Directory _directoryFor(String documentPath) => Directory(
    p.join(
      root.path,
      sha256.convert(documentPath.toLowerCase().codeUnits).toString(),
    ),
  );

  Future<void> create(String documentPath, int generations) async {
    final source = File(documentPath);
    if (!await source.exists() || generations <= 0) return;
    final directory = _directoryFor(documentPath);
    await directory.create(recursive: true);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    await source.copy(p.join(directory.path, '$stamp.tnote'));
    final entries = await list(documentPath);
    for (final old in entries.skip(generations)) {
      await File(old.path).delete();
    }
  }

  Future<List<BackupEntry>> list(String documentPath) async {
    final directory = _directoryFor(documentPath);
    if (!await directory.exists()) return [];
    final entries = <BackupEntry>[];
    await for (final item in directory.list()) {
      if (item is File && item.path.endsWith('.tnote')) {
        entries.add(BackupEntry(item.path, (await item.stat()).modified));
      }
    }
    entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return entries;
  }
}
