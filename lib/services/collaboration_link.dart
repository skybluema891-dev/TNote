import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'publish_file.dart';

/// Shared file association entry. Contains no credentials, memo text or paths.
class CollaborationLink {
  static const _prefix = 'TNote collaborative document v1\n';
  static final _valid = RegExp(r'^[a-f0-9]{64}$');

  static Future<String?> read(String path) async {
    final handle = await File(path).open();
    try {
      final header = await handle.read(_prefix.length);
      if (String.fromCharCodes(header) != _prefix) return null;
      final value = utf8.decode(await handle.read(67)).trim();
      if (await handle.position() != await handle.length() ||
          !_valid.hasMatch(value)) {
        throw const FormatException('共同編集ファイルの形式が正しくありません。');
      }
      return value;
    } finally {
      await handle.close();
    }
  }

  static File fileFor(Directory folder, String name, String identity) {
    final clean = String.fromCharCodes(name.runes.take(38))
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
    return File(
      p.join(
        folder.path,
        '${clean.isEmpty ? 'メモ' : clean}（共同編集-${identity.substring(0, 12)}）.tnote',
      ),
    );
  }

  static Future<File> create(
    Directory folder,
    String name,
    String id, {
    String? sourceFingerprint,
  }) async {
    if (!_valid.hasMatch(id)) throw const FormatException('共同メモの識別子が不正です。');
    final file = fileFor(folder, name, sourceFingerprint ?? id);
    final suffix = base64UrlEncode(
      List.generate(16, (_) => Random.secure().nextInt(256)),
    );
    final stage = File(p.join(folder.path, '.tnote-link-$suffix.part'));
    await stage.create(exclusive: true);
    try {
      await stage.writeAsString('$_prefix$id\n', flush: true);
      try {
        await Isolate.run(() => publishFile(stage.path, file.path));
      } on FileSystemException {
        if (!await file.exists() || await read(file.path) != id) rethrow;
      }
    } finally {
      if (await stage.exists()) await stage.delete();
    }
    return file;
  }
}
