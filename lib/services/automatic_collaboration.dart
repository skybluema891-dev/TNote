import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'collaboration_session.dart';
import 'document_store.dart';
import 'publish_file.dart';

/// Automatically opens the same legacy .tnote as one collaboration room.
///
/// The original SQLite document is never replaced. The authority for future
/// edits is an immutable, atomically-published association beside that file.
/// The association contains the room's join secret: anyone with read access to
/// the shared directory can join. Only use this on a trusted, access-controlled
/// folder. No secret is committed to Git or an application configuration file.
class AutomaticCollaboration {
  static const _format = 'TNote automatic collaboration v1';
  static final _id = RegExp(r'^[a-f0-9]{64}$');
  static final _fingerprint = RegExp(r'^[a-f0-9]{64}$');

  static File association(File source) =>
      File('${source.path}.collaboration.json');

  static Future<AutomaticRoom> prepare({
    required File source,
    required Directory support,
  }) async {
    final canonical = File(await source.resolveSymbolicLinks());
    final sidecar = association(canonical);
    final store = DocumentStore();
    final fingerprint = await store.currentFingerprint(canonical.path);
    // A legacy editor must not write to the original file concurrently with
    // a new room, even when the association has already been created.
    await _ensureNoLegacyWriter(canonical);
    if (await sidecar.exists()) {
      return _read(sidecar, fingerprint, canonical);
    }

    // Fresh .tnote-lock files are retained, never removed by auto-migration.
    // Each contender creates its own validated, locally backed-up room. The
    // atomic association publish picks a single winner if two PCs open at
    // precisely the same time. Losing rooms are never exposed to other PCs.
    final key = CollaborationSession.newKey();
    final cache = Directory(p.join(support.path, 'collaboration-v1'));
    final snapshots = Directory(p.join(cache.path, 'auto-migration'));
    await snapshots.create(recursive: true);
    final session = await CollaborationSession.open(
      support: cache,
      exchange: canonical.parent,
      code: key,
    );
    try {
      final backup = Directory(p.join(snapshots.path, session.room));
      await backup.create(recursive: true);
      final original = File(p.join(backup.path, 'original.tnote'));
      if (!await original.exists()) {
        await store.backupWorkspace(canonical.path, original.path);
      }
      final workspace = await store.openWorkspace(original.path);

      await session.createExchange();
      session.edit((replica) {
        replica.seed(workspace);
        replica.document.getMap('workspace')['name'] =
            p.basenameWithoutExtension(canonical.path);
      });
      await session.sync();
      if (!session.status.startsWith('共有フォルダーへ保存済み')) {
        throw StateError('共同編集の初期データを共有フォルダーへ保存できませんでした。');
      }

      // Do not publish an association based on an out-of-date source.
      await _ensureNoLegacyWriter(canonical);
      if (await store.currentFingerprint(canonical.path) != fingerprint) {
        throw StateError('移行中に原本が変更されました。閉じてから再度開いてください。');
      }

      final body = jsonEncode({
        'format': _format,
        'source_sha256': fingerprint,
        'room': session.room,
        'join_key': key,
      });
      final stage = File(
        p.join(
          canonical.parent.path,
          '.tnote-auto-${session.room.substring(0, 16)}.part',
        ),
      );
      // An exclusive stage avoids concurrent writers sharing a temp file.
      await stage.create(exclusive: true);
      try {
        await stage.writeAsString(body, flush: true);
        try {
          await Isolate.run(() => publishFile(stage.path, sidecar.path));
        } on FileSystemException {
          // Another PC may have committed its own room first.
          if (!await sidecar.exists()) rethrow;
        }
      } finally {
        if (await stage.exists()) await stage.delete();
      }
    } finally {
      await session.shutdown();
    }
    return _read(sidecar, fingerprint, canonical);
  }

  static Future<void> _ensureNoLegacyWriter(File source) async {
    final lock = File('${source.path}.tnote-lock');
    if (!await lock.exists()) return;
    try {
      if (await lock.length() > 8192) return;
      final json = jsonDecode(await lock.readAsString());
      if (json is! Map) return;
      final updated = DateTime.tryParse(json['updatedAt'] as String? ?? '');
      if (updated != null &&
          DateTime.now().toUtc().difference(updated).abs() <
              const Duration(minutes: 2)) {
        throw StateError(
          'このファイルは従来方式のTNoteで使用中です。'
          '元のファイルを保存して閉じ、両方の端末を新版にして開き直してください。',
        );
      }
    } on StateError {
      rethrow;
    } on FormatException {
      // A damaged or partial old heartbeat cannot authorize deletion.
    } on FileSystemException {
      // The source hash is checked again before publish.
    }
  }

  static Future<AutomaticRoom> _read(
    File sidecar,
    String fingerprint,
    File source,
  ) async {
    if (await sidecar.length() > 4096) {
      throw const FormatException('共同編集情報が大きすぎます。');
    }
    final record = jsonDecode(await sidecar.readAsString());
    if (record is! Map ||
        record['format'] != _format ||
        record['source_sha256'] is! String ||
        record['room'] is! String ||
        record['join_key'] is! String) {
      throw const FormatException('共同編集情報が正しくありません。');
    }
    final storedHash = record['source_sha256'] as String;
    final room = record['room'] as String;
    final key = record['join_key'] as String;
    if (!_fingerprint.hasMatch(storedHash) || !_id.hasMatch(room)) {
      throw const FormatException('共同編集情報が正しくありません。');
    }
    List<int> decoded;
    try {
      decoded = base64Url.decode(key);
    } on FormatException {
      throw const FormatException('共同編集の参加情報が正しくありません。');
    }
    if (decoded.length != 32 ||
        sha256.convert([...utf8.encode('TNote room 1'), ...decoded]).toString() !=
            room) {
      throw const FormatException('共同編集の参加情報が正しくありません。');
    }
    if (storedHash != fingerprint) {
      throw StateError(
        '共同編集の開始後に元の.tnoteが別のアプリで変更されました。'
        '内容を上書きせず、元のファイルを保護しています。変更内容を確認してください。',
      );
    }
    return AutomaticRoom(
      room: room,
      key: key,
      directory: source.parent,
      displayName: p.basenameWithoutExtension(source.path),
    );
  }
}

class AutomaticRoom {
  const AutomaticRoom({
    required this.room,
    required this.key,
    required this.directory,
    required this.displayName,
  });
  final String room;
  final String key;
  final Directory directory;
  final String displayName;

  Map<String, dynamic> get link => {
    'id': room,
    'path': directory.path,
    'name': displayName,
    'autoCode': key,
  };
}
