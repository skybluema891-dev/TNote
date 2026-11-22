import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tnote/services/collaboration_link.dart';
import 'package:tnote/services/collaboration_session.dart';
import 'package:tnote/services/document_store.dart';

// Operator tool. Receives one newly generated room key through standard input.
// Neither the key nor any document text is written to the console.
Future<void> main(List<String> args) async {
  if (args.length != 5) {
    stderr.writeln('元ファイル、SHA-256、共有先、端末内の退避先、表示名を指定してください。');
    exitCode = 2;
    return;
  }
  try {
    await stage(args, stdin.readLineSync() ?? '');
    stdout.writeln('バックアップと移行先の照合が完了しました。');
  } catch (error) {
    if (error is StateError) {
      stderr.writeln(error.message);
    } else {
      stderr.writeln('移行を完了できませんでした。元ファイルと退避先を確認してください。');
    }
    exitCode = 1;
  }
}

Future<void> stage(List<String> args, String key) async {
  final source = File(args[0]).absolute;
  final fingerprint = args[1].toLowerCase();
  final exchange = Directory(args[2]).absolute;
  final local = Directory(args[3]).absolute;
  final title = args[4].trim();
  if (title.isEmpty ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint) ||
      !await exchange.exists() ||
      p.equals(local.path, exchange.path) ||
      p.isWithin(exchange.path, local.path) ||
      p.isWithin(local.path, exchange.path)) {
    throw StateError('共有先と端末内の退避先に別々のフォルダーを指定してください。');
  }
  final store = DocumentStore();
  if (await store.currentFingerprint(source.path) != fingerprint) {
    throw StateError('元ファイルが変更されています。バックアップを照合してください。');
  }
  final session = await CollaborationSession.open(
    support: Directory(p.join(local.path, 'cache')),
    exchange: exchange,
    code: key,
  );
  try {
    final name = CollaborationLink.fileFor(exchange, title, fingerprint);
    if (await name.exists()) {
      if (await CollaborationLink.read(name.path) != session.room) {
        throw StateError('同名ファイルが別の共同メモを指しています。');
      }
      await verifyExchange(local, exchange, key, session.room, fingerprint);
      return;
    }
    final backupDir = Directory(p.join(local.path, 'migration', session.room));
    await backupDir.create(recursive: true);
    final backup = File(p.join(backupDir.path, 'original.tnote'));
    if (!await backup.exists()) {
      await store.backupWorkspace(source.path, backup.path);
    }
    final original = await store.openWorkspace(source.path);
    final verified = await store.openWorkspace(backup.path);
    final expected = shape(original);
    if (expected != shape(verified) ||
        await store.currentFingerprint(source.path) != fingerprint) {
      throw StateError('復旧用コピーが元ファイルと一致しません。');
    }
    await session.createExchange();
    await session.sync();
    if (session.replica.titles.isEmpty) {
      if (!await session.directory.list().isEmpty) {
        throw StateError('共有先に読み込めない既存の更新が残っています。');
      }
      session.edit((replica) {
        replica.seed(verified);
        final meta = replica.document.getMap('workspace');
        meta['name'] = title;
        meta['importFingerprint'] = fingerprint;
      });
    }
    if (session.replica.document.getMap('workspace')['importFingerprint'] !=
        fingerprint) {
      throw StateError('参加キーが別のメモに使われています。');
    }
    await session.sync();
    await verifyExchange(
      local,
      exchange,
      key,
      session.room,
      fingerprint,
      expected: expected,
    );
    await CollaborationLink.create(
      exchange,
      title,
      session.room,
      sourceFingerprint: fingerprint,
    );
  } finally {
    await session.shutdown();
  }
}

Future<void> verifyExchange(
  Directory local,
  Directory exchange,
  String key,
  String room,
  String fingerprint, {
  String? expected,
}) async {
  final checkRoot = await local.createTemp('verify-');
  CollaborationSession? reader;
  try {
    reader = await CollaborationSession.open(
      support: checkRoot,
      exchange: exchange,
      code: key,
    );
    await reader.sync();
    if (reader.replica.document.getMap('workspace')['importFingerprint'] !=
        fingerprint) {
      throw StateError('移行済みメモを共有先から確認できません。再接続してやり直してください。');
    }
    if (expected != null &&
        (reader.replica.titles.isEmpty ||
            shape(reader.replica.workspace()) != expected)) {
      throw StateError('共有先から再取得した本文・書式・構造が一致しません。');
    }
  } finally {
    await reader?.shutdown();
    final copied = File(p.join(checkRoot.path, '$room.sqlite'));
    if (await copied.exists()) await copied.delete();
    if (await checkRoot.list().isEmpty) await checkRoot.delete();
  }
}

// Quill may combine adjacent equal-style runs during a round trip.
String shape(StoredWorkspace workspace) {
  Object? canonical(Object? value) {
    if (value is List) return value.map(canonical).toList();
    if (value is Map) {
      return SplayTreeMap<String, Object?>.from({
        for (final entry in value.entries)
          entry.key as String: canonical(entry.value),
      });
    }
    return value;
  }

  List<dynamic> runs(List<dynamic> delta) {
    final out = <Map<String, dynamic>>[];
    for (final raw in delta.cast<Map>()) {
      final text = raw['insert'];
      if (text is! String) throw StateError('未対応の埋め込みを検出しました。元ファイルは保持されています。');
      final style = jsonEncode(canonical(raw['attributes'] ?? {}));
      if (out.isNotEmpty && out.last['style'] == style) {
        out.last['text'] = (out.last['text'] as String) + text;
      } else {
        out.add({'text': text, 'style': style});
      }
    }
    return out;
  }

  return jsonEncode([
    workspace.activeDocumentId,
    for (final doc in workspace.documents)
      [
        doc.id,
        doc.name,
        doc.activeTabId,
        for (final tab in doc.tabs)
          [tab.id, tab.name, tab.createdAt, tab.updatedAt, runs(tab.delta)],
      ],
  ]);
}
