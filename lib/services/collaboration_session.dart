import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'collaboration_replica.dart';

/// Immutable, authenticated update blocks are exchanged through a private
/// shared directory. SQLite is local to one installation, never on the share.
class CollaborationSession extends ChangeNotifier {
  CollaborationSession._(this.directory, this.room, this._key, this._db);
  final Directory directory;
  final String room;
  final SecretKey _key;
  final Database _db;
  final replica = CollaborationReplica();
  final _cipher = AesGcm.with256bits();
  static final _name = RegExp(r'^[0-9a-f]{64}\.op$');
  final _known = <String>{};
  Timer? _timer;
  Future<void>? _sync;
  bool _closed = false;
  bool Function()? deferReceive;
  void Function()? onReceive;
  String status = '端末内に保存済み・同期待ち';
  bool localFailure = false;
  bool paused = false;

  static String newKey() {
    final rng = Random.secure();
    return base64UrlEncode(List.generate(32, (_) => rng.nextInt(256)));
  }

  static Future<CollaborationSession> open({
    required Directory support,
    required Directory exchange,
    required String code,
  }) async {
    Uint8List raw;
    try {
      raw = base64Url.decode(code.trim());
    } catch (_) {
      throw const FormatException('参加キーが正しくありません。');
    }
    if (raw.length != 32) throw const FormatException('参加キーが正しくありません。');
    final room = hashes.sha256.convert([
      ...utf8.encode('TNote room 1'),
      ...raw,
    ]).toString();
    await support.create(recursive: true);
    final db = sqlite3.open(p.join(support.path, '$room.sqlite'));
    final session = CollaborationSession._(
      Directory(p.join(exchange.path, 'TNote-$room')),
      room,
      SecretKey(raw),
      db,
    );
    try {
      db.execute('PRAGMA busy_timeout=3000');
      db.execute('PRAGMA synchronous=FULL');
      db.execute(
        'CREATE TABLE IF NOT EXISTS blocks (id TEXT PRIMARY KEY, data BLOB NOT NULL, published INTEGER NOT NULL)',
      );
      for (final row in db.select(
        'SELECT id,data FROM blocks ORDER BY rowid',
      )) {
        session.replica.receive(row['data'] as Uint8List);
        session._known.add(row['id'] as String);
      }
      return session;
    } catch (_) {
      session.replica.close();
      db.close();
      rethrow;
    }
  }

  void edit(void Function(CollaborationReplica replica) edit) {
    if (localFailure) throw StateError(status);
    final delta = replica.change(() => edit(replica));
    final id = hashes.sha256.convert(delta).toString();
    try {
      _db.execute('INSERT OR IGNORE INTO blocks VALUES (?,?,0)', [id, delta]);
      _known.add(id);
    } catch (_) {
      localFailure = true;
      _setStatus('端末内に保存できません。画面を開いたまま空き容量を確認してください。');
      rethrow;
    }
    _setStatus('端末内に保存済み・同期待ち');
  }

  Future<void> createExchange() async {
    // Creating a new room requires an online, user-selected parent.
    if (!await directory.parent.exists()) {
      throw const FileSystemException('共有先に接続できません。');
    }
    await directory.create();
  }

  void start() {
    _timer ??= Timer.periodic(
      const Duration(milliseconds: 350),
      (_) => unawaited(sync()),
    );
    unawaited(sync());
  }

  void _setStatus(String value) {
    if (!_closed && status != value) {
      status = value;
      notifyListeners();
    }
  }

  Future<void> sync() {
    if (_closed || paused || localFailure) return Future.value();
    return _sync ??= _exchange().whenComplete(() {
      _sync = null;
    });
  }

  Future<void> _exchange() async {
    try {
      if (!await directory.exists()) {
        throw const FileSystemException('共有フォルダーが見つかりません');
      }
      final files = await directory
          .list(followLinks: false)
          .where((e) => e is File && _name.hasMatch(p.basename(e.path)))
          .toList();
      final visible = {
        for (final f in files) p.basenameWithoutExtension(f.path),
      };
      final aad = utf8.encode('TNote/1/$room');
      // Reconcile rows written by another window on the same installation.
      bool changed = false;
      if (deferReceive?.call() != true) {
        for (final row in _db.select('SELECT id FROM blocks WHERE rowid > ?', [
          _seenRow,
        ])) {
          final id = row['id'] as String;
          if (!_known.contains(id)) {
            if (deferReceive?.call() == true) break;
            replica.receive(
              _db.select('SELECT data FROM blocks WHERE id=?', [
                    id,
                  ]).single['data']
                  as Uint8List,
            );
            _known.add(id);
            changed = true;
          }
          _seenRow++;
        }
        if (changed) onReceive?.call();
      }
      for (final f in files) {
        final id = p.basenameWithoutExtension(f.path);
        if (_known.contains(id) || deferReceive?.call() == true) continue;
        if (await (f as File).length() > 128 * 1024 * 1024) {
          throw const FormatException('更新データの容量が大きすぎます。');
        }
        final box = SecretBox.fromConcatenation(
          await f.readAsBytes(),
          nonceLength: 12,
          macLength: 16,
        );
        final plain = Uint8List.fromList(
          await _cipher.decrypt(box, secretKey: _key, aad: aad),
        );
        if (hashes.sha256.convert(plain).toString() != id) {
          throw const FormatException('更新データが一致しません。');
        }
        if (_closed || deferReceive?.call() == true) break;
        replica.receive(plain);
        _db.execute('INSERT OR IGNORE INTO blocks VALUES (?,?,1)', [id, plain]);
        _known.add(id);
        onReceive?.call();
      }
      for (final row in _db.select(
        'SELECT id,data FROM blocks WHERE published=0',
      )) {
        final id = row['id'] as String;
        if (!visible.contains(id)) {
          _setStatus('同期中・端末内に保存済み');
          final box = await _cipher.encrypt(
            row['data'] as Uint8List,
            secretKey: _key,
            aad: aad,
          );
          final file = File(p.join(directory.path, '$id.op'));
          final part = File('${file.path}.${replica.document.peerId}.part');
          await part.writeAsBytes(box.concatenation(), flush: true);
          try {
            await part.rename(file.path);
          } on FileSystemException {
            if (!await file.exists()) rethrow;
          } finally {
            if (await part.exists()) await part.delete();
          }
        }
        _db.execute('UPDATE blocks SET published=1 WHERE id=?', [id]);
      }
      if (!localFailure) _setStatus('共有フォルダーへ保存済み・他端末の受信を待機');
    } catch (error) {
      if (!localFailure) {
        _setStatus(
          error is SecretBoxAuthenticationError || error is FormatException
              ? '更新データを検証できません。元の履歴を保持して再試行します。'
              : '共有先に接続できません・端末内に保存して自動再試行します',
        );
      }
    }
  }

  int _seenRow = 0;

  Future<void> shutdown() async {
    _closed = true;
    _timer?.cancel();
    await _sync;
    replica.close();
    _db.close();
    dispose();
  }
}
