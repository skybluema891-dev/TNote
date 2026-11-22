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
import 'document_store.dart';

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
  Uint8List? _unsaved;
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
      db.execute(
        'CREATE TABLE IF NOT EXISTS history (seq INTEGER PRIMARY KEY, at INTEGER NOT NULL)',
      );
      db.execute(
        "CREATE TRIGGER IF NOT EXISTS remember_block AFTER INSERT ON blocks BEGIN INSERT INTO history VALUES (NEW.rowid,unixepoch()); END",
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
    _unsaved = delta;
    _persistPending();
  }

  bool _persistPending() {
    final delta = _unsaved;
    if (delta == null) return true;
    final id = hashes.sha256.convert(delta).toString();
    try {
      _db.execute('INSERT OR IGNORE INTO blocks VALUES (?,?,0)', [id, delta]);
      _known.add(id);
      _unsaved = null;
      localFailure = false;
    } catch (_) {
      localFailure = true;
      _setStatus('端末内に保存できません。画面を開いたまま空き容量を確認してください。');
      return false;
    }
    _setStatus(paused ? '通信を一時停止中・端末内に保存済み' : '端末内に保存済み・同期待ち');
    return true;
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
    if (_closed || paused || !_persistPending()) return Future.value();
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
        for (final row in _db.select(
          'SELECT rowid,id FROM blocks WHERE rowid > ? ORDER BY rowid',
          [_seenRow],
        )) {
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
          _seenRow = row['rowid'] as int;
        }
        if (changed) onReceive?.call();
      }
      var damaged = false;
      for (final f in files) {
        final id = p.basenameWithoutExtension(f.path);
        if (_known.contains(id) || deferReceive?.call() == true) continue;
        final plain = await _verified(f as File, id, aad);
        if (plain == null) {
          damaged = true;
          continue;
        }
        if (_closed || paused || deferReceive?.call() == true) break;
        replica.receive(plain);
        _db.execute('INSERT OR IGNORE INTO blocks VALUES (?,?,1)', [id, plain]);
        _known.add(id);
        onReceive?.call();
      }
      for (final row in _db.select(
        'SELECT id,data FROM blocks WHERE published=0',
      )) {
        final id = row['id'] as String;
        if (_closed || paused) return;
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
        } else if (await _verified(
              File(p.join(directory.path, '$id.op')),
              id,
              aad,
            ) ==
            null) {
          damaged = true;
          continue;
        }
        _db.execute('UPDATE blocks SET published=1 WHERE id=?', [id]);
      }
      if (!localFailure && !paused) {
        _setStatus(
          damaged
              ? '一部の更新を検証できません。端末内の履歴を保持して再試行します。'
              : '共有フォルダーへ保存済み・他端末の受信を待機',
        );
      }
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

  Future<Uint8List?> _verified(File file, String id, List<int> aad) async {
    final length = await file.length();
    if (length < 28 || length > 128 * 1024 * 1024) return null;
    final box = SecretBox.fromConcatenation(
      await file.readAsBytes(),
      nonceLength: 12,
      macLength: 16,
    );
    try {
      final data = Uint8List.fromList(
        await _cipher.decrypt(box, secretKey: _key, aad: aad),
      );
      return hashes.sha256.convert(data).toString() == id ? data : null;
    } on SecretBoxAuthenticationError {
      return null;
    }
  }

  List<({int sequence, DateTime time})> get history => [
    for (final row in _db.select(
      'SELECT seq,at FROM history ORDER BY seq DESC LIMIT 100',
    ))
      (
        sequence: row['seq'] as int,
        time: DateTime.fromMillisecondsSinceEpoch((row['at'] as int) * 1000),
      ),
  ];

  StoredWorkspace restoreAt(int sequence) {
    final copy = CollaborationReplica();
    try {
      for (final row in _db.select(
        'SELECT data FROM blocks WHERE rowid <= ? ORDER BY rowid',
        [sequence],
      )) {
        copy.receive(row['data'] as Uint8List);
      }
      return copy.workspace();
    } finally {
      copy.close();
    }
  }

  Future<void> shutdown() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    await _sync;
    replica.close();
    _db.close();
    dispose();
  }
}
