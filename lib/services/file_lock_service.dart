import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class FileAlreadyOpen implements Exception {
  const FileAlreadyOpen([this.owner]);
  final String? owner;
  @override
  String toString() =>
      owner == null ? 'このファイルはすでに別のTNoteで開かれています。' : 'このファイルは「$owner」で開かれています。';
}

class FileLockService {
  FileLockService(this.directory);
  final Directory directory;
  final Map<String, RandomAccessFile> _locks = {};
  final Map<String, _SharedLock> _sharedLocks = {};
  Timer? _heartbeat;
  Future<void>? _refreshing;

  String _key(String path) =>
      sha256.convert(path.toLowerCase().codeUnits).toString();

  Future<void> acquire(String documentPath) async {
    final key = _key(documentPath);
    if (_locks.containsKey(key)) return;
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, '$key.lock'));
    final handle = await file.open(mode: FileMode.append);
    try {
      try {
        await handle.lock(FileLock.exclusive);
      } on FileSystemException catch (error) {
        if ({11, 35, 33}.contains(error.osError?.errorCode)) {
          throw const FileAlreadyOpen();
        }
        rethrow;
      }
      final sharedFile = File('$documentPath.tnote-lock');
      if (await sharedFile.exists()) {
        try {
          final data = Map<String, dynamic>.from(
            jsonDecode(await sharedFile.readAsString()) as Map,
          );
          final updated = DateTime.tryParse(data['updatedAt'] as String? ?? '');
          if (updated != null &&
              DateTime.now().toUtc().difference(updated).abs() <
                  const Duration(minutes: 2)) {
            throw FileAlreadyOpen(data['device'] as String?);
          }
        } on FileAlreadyOpen {
          rethrow;
        } catch (_) {
          // 壊れた、または同期途中の古いロックは新しい所有情報で置き換える。
        }
      }
      final token =
          '${Platform.localHostname}-$pid-${DateTime.now().microsecondsSinceEpoch}';
      final shared = _SharedLock(sharedFile, token, documentPath);
      await _writeSharedLock(shared);
      await handle.setPosition(0);
      await handle.truncate(0);
      await handle.writeString(
        jsonEncode({
          'pid': pid,
          'path': documentPath,
          'openedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      await handle.flush();
      _locks[key] = handle;
      _sharedLocks[key] = shared;
      _heartbeat ??= Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(_queueRefresh()),
      );
    } catch (_) {
      await handle.close();
      rethrow;
    }
  }

  Future<void> release(String documentPath) async {
    final key = _key(documentPath);
    final shared = _sharedLocks.remove(key);
    // A heartbeat that was already running must finish before the lock file is
    // removed. Otherwise it can write the file back immediately after deletion.
    await _waitForRefresh();
    if (shared != null) await _removeSharedLock(shared);
    final handle = _locks.remove(key);
    if (handle == null) return;
    await handle.unlock();
    await handle.close();
  }

  Future<void> releaseAll() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    // Remove the entries first so an in-flight heartbeat will not refresh them.
    final sharedLocks = _sharedLocks.values.toList(growable: false);
    _sharedLocks.clear();
    await _waitForRefresh();
    for (final shared in sharedLocks) {
      await _removeSharedLock(shared);
    }
    for (final handle in _locks.values) {
      await handle.unlock();
      await handle.close();
    }
    _locks.clear();
  }

  Future<void> _queueRefresh() {
    final running = _refreshing;
    if (running != null) return running;
    final refresh = _refreshSharedLocks();
    _refreshing = refresh.whenComplete(() => _refreshing = null);
    return _refreshing!;
  }

  Future<void> _waitForRefresh() async {
    final refresh = _refreshing;
    if (refresh != null) await refresh;
  }

  Future<void> _refreshSharedLocks() async {
    final sharedLocks = _sharedLocks.entries.toList(growable: false);
    for (final entry in sharedLocks) {
      // It may have been released while this heartbeat was waiting on OneDrive.
      if (!identical(_sharedLocks[entry.key], entry.value)) continue;
      try {
        await _writeSharedLock(entry.value);
      } catch (_) {}
    }
  }

  Future<void> _writeSharedLock(_SharedLock shared) async {
    await shared.file.writeAsString(
      jsonEncode({
        'token': shared.token,
        'device': Platform.localHostname,
        'pid': pid,
        'path': shared.documentPath,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
  }

  Future<void> _removeSharedLock(_SharedLock shared) async {
    // OneDrive can briefly hold a file while applying a sync update. Retry a
    // few times, but only delete a lock carrying this app instance's token.
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        if (!await shared.file.exists()) return;
        final data = Map<String, dynamic>.from(
          jsonDecode(await shared.file.readAsString()) as Map,
        );
        if (data['token'] != shared.token) return;
        await shared.file.delete();
        if (!await shared.file.exists()) return;
      } on FileSystemException {
        // Retry below.
      } on FormatException {
        // A concurrent OneDrive update may be temporarily incomplete.
      } catch (_) {
        return;
      }
      await Future<void>.delayed(Duration(milliseconds: 100 * (attempt + 1)));
    }
  }
}

class _SharedLock {
  const _SharedLock(this.file, this.token, this.documentPath);
  final File file;
  final String token;
  final String documentPath;
}
