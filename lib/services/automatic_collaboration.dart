import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:unorm_dart/unorm_dart.dart' as unicode;

import '../models/document.dart';
import 'collaboration_session.dart';
import 'document_store.dart';
import 'publish_file.dart';

/// The original SQLite image, including its document and tab IDs, is the
/// private enrollment material for a new automatic room. Its public SHA-256
/// fingerprint and the public room identifier cannot substitute for it.
/// Existing v1 associations retain their original random key and history.
class AutomaticCollaboration {
  static const _legacy = 'TNote automatic collaboration v1';
  static const _format = 'TNote automatic collaboration v2';
  static final _id = RegExp(r'^[a-f0-9]{64}$');

  static File association(File source) =>
      File('${source.path}.collaboration.json');

  static Future<AutomaticRoom> prepare({
    required File source,
    required Directory support,
  }) async {
    final canonical = File(await source.resolveSymbolicLinks());
    final sidecar = association(canonical);
    final store = DocumentStore();
    await _ensureNoLegacyWriter(canonical);
    final fingerprint = await store.currentFingerprint(canonical.path);
    final record = await sidecar.exists()
        ? await _read(sidecar, fingerprint)
        : null;
    final displayName = p.basenameWithoutExtension(canonical.path);
    final cache = Directory(p.join(support.path, 'collaboration-v1'));
    final directoryId = _pathId(canonical.parent.path);
    final binding = File(
      p.join(
        cache.path,
        'auto-bindings',
        '${_pathId(canonical.path)}-$fingerprint.json',
      ),
    );
    if (record?['format'] == _legacy) {
      final key = record!['join_key'];
      if (key is! String || key.length > 64) throw _badKey;
      late final List<int> raw;
      try {
        raw = base64Url.decode(key);
      } on FormatException {
        throw _badKey;
      }
      if (raw.length != 32 ||
          CollaborationSession.roomId(raw) != record['room']) {
        throw _badKey;
      }
      await _bind(binding, record['room'] as String);
      await _rememberOffline(cache, source, canonical, {
        'format': _legacy,
        'room': record['room'],
      });
      return AutomaticRoom(
        room: record['room'] as String,
        key: key,
        directory: canonical.parent,
        displayName: displayName,
      );
    }

    final namespace = record == null
        ? unicode.nfc(displayName).toLowerCase()
        : record['namespace'];
    if (namespace is! String || !_validNamespace(namespace)) throw _badRecord;
    final (key, room) = await _credentials(canonical, namespace);
    if (record != null && record['room'] != room) throw _badKey;
    await _checkBinding(binding, room);
    final result = AutomaticRoom(
      room: room,
      key: key,
      directory: canonical.parent,
      displayName: displayName,
      cacheScope: directoryId,
    );
    final session = await CollaborationSession.open(
      support: result.cacheIn(cache),
      exchange: canonical.parent,
      code: key,
    );
    try {
      if (session.replica.titles.isEmpty) {
        final backup = File(
          p.join(cache.path, 'auto-migration', room, 'original.tnote'),
        );
        if (!await backup.exists()) {
          await backup.parent.create(recursive: true);
          // Keep the original bytes for recovery of both the note and its key.
          final stage = File(
            p.join(backup.parent.path, 'original-${newId()}.part'),
          );
          try {
            await canonical.copy(stage.path);
            if (await store.currentFingerprint(stage.path) != fingerprint) {
              throw _changed;
            }
            await _publishOrObserve(stage, backup);
          } finally {
            if (await stage.exists()) await stage.delete();
          }
        }
        if (await store.currentFingerprint(backup.path) != fingerprint) {
          throw _changed;
        }
        final workspace = await store.openWorkspace(backup.path);
        session.seedAutomatic(workspace, namespace);
      }
      // Never seed a second room on resume or replace an existing history.
      // Only a brand new association needs an online parent to publish into.
      if (record == null) {
        await session.createExchange();
        await session.sync();
        if (!session.status.startsWith('共有フォルダーへ保存済み')) {
          throw StateError('共同編集の初期データを共有フォルダーへ保存できませんでした。端末内に保持しています。');
        }
      }
      await _ensureNoLegacyWriter(canonical);
      if (await store.currentFingerprint(canonical.path) != fingerprint) {
        throw _changed;
      }
      if (record == null) {
        final body = jsonEncode({
          'format': _format,
          'source_sha256': fingerprint,
          'namespace': namespace,
          'room': room,
        });
        await _writeOnce(sidecar, body);
        final published = await _read(sidecar, fingerprint);
        if (published['room'] != room ||
            published['format'] != _format ||
            published['namespace'] != namespace) {
          throw _conflict;
        }
      }
      await _bind(binding, room);
      await _rememberOffline(cache, source, canonical, {
        'format': _format,
        'source_sha256': fingerprint,
        'namespace': namespace,
        'room': room,
        'directory': canonical.parent.path,
      });
      return result;
    } finally {
      await session.shutdown();
    }
  }

  static bool _validNamespace(String value) =>
      value.isNotEmpty &&
      value.length <= 255 &&
      !value.contains(RegExp(r'[/\\\x00]'));

  static Future<(String, String)> _credentials(
    File original,
    String namespace,
  ) async {
    // Hash the whole file as the message. Using it as the HMAC key would
    // reduce it to the public SHA-256 fingerprint before hashing the message.
    final hash = await Hmac(
      sha256,
      utf8.encode('TNote automatic enrollment v2\u0000$namespace\u0000'),
    ).bind(original.openRead()).first;
    return (
      base64UrlEncode(hash.bytes),
      CollaborationSession.roomId(hash.bytes),
    );
  }

  static File _offlineIndex(Directory cache, File source) => File(
    p.join(cache.path, 'auto-offline', '${_pathId(source.absolute.path)}.json'),
  );

  static Future<void> _rememberOffline(
    Directory cache,
    File source,
    File canonical,
    Map<String, dynamic> record,
  ) async {
    final body = jsonEncode(record);
    final paths = {
      _offlineIndex(cache, source).path,
      _offlineIndex(cache, canonical).path,
    };
    for (final path in paths) {
      final file = File(path);
      if (await file.exists() &&
          await file.length() == utf8.encode(body).length &&
          await file.readAsString() == body) {
        continue;
      }
      await file.parent.create(recursive: true);
      final stage = File(p.join(file.parent.path, 'index-${newId()}.part'));
      try {
        await stage.writeAsString(body, flush: true);
        await stage.rename(file.path);
      } finally {
        if (await stage.exists()) await stage.delete();
      }
    }
  }

  /// Resume a previously opened path when the share itself is unavailable.
  /// Never creates a new room, local database, or network directory.
  static Future<AutomaticRoom?> openOffline({
    required File source,
    required Directory support,
  }) async {
    final cache = Directory(p.join(support.path, 'collaboration-v1'));
    final index = _offlineIndex(cache, source);
    if (!await index.exists()) return null;
    if (await index.length() > 131072) throw _badRecord;
    final record = jsonDecode(await index.readAsString());
    if (record is! Map<String, dynamic>) throw _badRecord;
    if (record['format'] == _legacy) return null;
    final room = record['room'],
        namespace = record['namespace'],
        fingerprint = record['source_sha256'],
        path = record['directory'];
    if (record['format'] != _format ||
        room is! String ||
        !_id.hasMatch(room) ||
        fingerprint is! String ||
        !_id.hasMatch(fingerprint) ||
        namespace is! String ||
        !_validNamespace(namespace) ||
        path is! String ||
        !p.isAbsolute(path)) {
      throw _badRecord;
    }
    final backup = File(
      p.join(cache.path, 'auto-migration', room, 'original.tnote'),
    );
    if (!await backup.exists() ||
        await DocumentStore().currentFingerprint(backup.path) != fingerprint) {
      throw StateError('端末の原本バックアップを確認できません。共有先に再接続してください。');
    }
    final (key, expectedRoom) = await _credentials(backup, namespace);
    if (room != expectedRoom) throw _badKey;
    final result = AutomaticRoom(
      room: room,
      key: key,
      directory: Directory(path),
      displayName: p.basenameWithoutExtension(source.path),
      cacheScope: _pathId(path),
    );
    if (!await File(p.join(result.cacheIn(cache).path, '$room.sqlite'))
        .exists()) {
      throw StateError('端末の編集履歴が見つかりません。共有先に再接続してください。');
    }
    return result;
  }

  static const _badRecord = FormatException('共同編集情報が正しくありません。');
  static const _badKey = FormatException('共同編集の参加情報が正しくありません。');
  static StateError get _changed =>
      StateError('共同編集の開始後に原本が変更されています。原本と端末内の編集履歴を保護しています。');
  static StateError get _conflict => StateError(
    '同じ原本に異なる共同編集情報が見つかりました。端末内の未同期編集を保持しています。'
    '元の参加情報とバックアップを確認してください。',
  );

  static String _pathId(String path) {
    final normalized = p.normalize(path);
    return sha256
        .convert(
          utf8.encode(
            Platform.isWindows ? normalized.toLowerCase() : normalized,
          ),
        )
        .toString();
  }

  static Future<Map<String, dynamic>> _read(
    File file,
    String fingerprint,
  ) async {
    if (await file.length() > 4096) throw _badRecord;
    final record = jsonDecode(await file.readAsString());
    if (record is! Map<String, dynamic> ||
        (record['format'] != _legacy && record['format'] != _format) ||
        record['room'] is! String ||
        !_id.hasMatch(record['room'] as String) ||
        record['source_sha256'] is! String ||
        !_id.hasMatch(record['source_sha256'] as String)) {
      throw _badRecord;
    }
    if (record['source_sha256'] != fingerprint) throw _changed;
    return record;
  }

  static Future<void> _checkBinding(File file, String room) async {
    if (await file.exists() &&
        (await file.length() != room.length ||
            await file.readAsString() != room)) {
      throw _conflict;
    }
  }

  static Future<void> _bind(File file, String room) async {
    if (!await file.exists()) {
      await file.parent.create(recursive: true);
      await _writeOnce(file, room);
    }
    await _checkBinding(file, room);
  }

  static Future<void> _writeOnce(File target, String text) async {
    final stage = File(
      p.join(target.parent.path, '.tnote-auto-${newId()}.part'),
    );
    await stage.create(exclusive: true);
    try {
      await stage.writeAsString(text, flush: true);
      await _publishOrObserve(stage, target);
    } finally {
      if (await stage.exists()) await stage.delete();
    }
  }

  static Future<void> _publishOrObserve(File stage, File target) async {
    try {
      await Isolate.run(() => publishFile(stage.path, target.path));
    } on FileSystemException {
      if (!await target.exists()) rethrow;
    }
  }

  static Future<void> _ensureNoLegacyWriter(File source) async {
    final wal = File('${source.path}-wal');
    if (await wal.exists() && await wal.length() > 0) {
      throw StateError('データベースの処理が完了するまで、元のアプリを閉じてから開き直してください。');
    }
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
}

class AutomaticRoom {
  const AutomaticRoom({
    required this.room,
    required this.key,
    required this.directory,
    required this.displayName,
    this.cacheScope,
  });
  final String room;
  final String key;
  final Directory directory;
  final String displayName;
  final String? cacheScope;

  Directory cacheIn(Directory base) => cacheForScope(base, cacheScope);

  static Directory cacheForScope(Directory base, String? scope) {
    if (scope == null) return base;
    if (!AutomaticCollaboration._id.hasMatch(scope)) {
      throw const FormatException('端末内の共同編集情報が正しくありません。');
    }
    return Directory(p.join(base.path, 'automatic', scope));
  }

  Map<String, dynamic> get link => {
    'id': room,
    'path': directory.path,
    'name': displayName,
    'autoCode': key,
    if (cacheScope != null) 'autoCacheScope': cacheScope,
  };
}
