import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tnote/models/document.dart';
import 'package:tnote/services/automatic_collaboration.dart';
import 'package:tnote/services/collaboration_session.dart';
import 'package:tnote/services/document_store.dart';

void main() {
  Future<(Directory, File, String)> fixture() async {
    final temp = await Directory.systemTemp.createTemp('tnote-auto-room-');
    final source = File(p.join(temp.path, 'shared', '仕事.tnote'));
    await source.parent.create(recursive: true);
    final doc = NoteDocument.create(1);
    await DocumentStore().saveWorkspace(
      [doc],
      doc.id,
      source.path,
      create: true,
    );
    return (
      temp,
      source,
      await DocumentStore().currentFingerprint(source.path),
    );
  }

  test('同じSQLiteファイルを開くだけで一つの共同編集室へ参加する', () async {
    final (temp, source, before) = await fixture();
    addTearDown(() => temp.delete(recursive: true));
    final computerA = Directory(p.join(temp.path, 'computerA'));
    final computerB = Directory(p.join(temp.path, 'computerB'));

    final rooms = await Future.wait([
      AutomaticCollaboration.prepare(source: source, support: computerA),
      AutomaticCollaboration.prepare(source: source, support: computerB),
    ]);
    expect(rooms[0].room, rooms[1].room);
    expect(rooms[0].key == rooms[1].key, isTrue);
    expect(rooms[0].link['path'], await source.parent.resolveSymbolicLinks());
    expect(rooms[1].link['autoCode'] == rooms[0].key, isTrue);
    expect(
      await DocumentStore().currentFingerprint(source.path),
      before,
      reason: '自動移行はSQLiteの原本を上書きしない',
    );
    expect(await AutomaticCollaboration.association(source).exists(), isTrue);
    expect(
      await AutomaticCollaboration.association(source).readAsString(),
      isNot(contains('document_text_should_not_be_here')),
    );

    final b = await CollaborationSession.open(
      support: Directory(p.join(computerB.path, 'collaboration-v1')),
      exchange: source.parent,
      code: rooms[1].key,
    );
    try {
      await b.sync();
      expect(b.replica.titles.isNotEmpty, isTrue);
      expect(b.replica.workspace().documents, isNotEmpty);
    } finally {
      await b.shutdown();
    }
    final reopened = await AutomaticCollaboration.prepare(
      source: source,
      support: computerB,
    );
    expect(reopened.room, rooms.first.room);
    expect(reopened.key == rooms.first.key, isTrue);
  });

  test('旧方式で開かれている原本は移行せず保護する', () async {
    final (temp, source, before) = await fixture();
    addTearDown(() => temp.delete(recursive: true));
    await File('${source.path}.tnote-lock').writeAsString(
      jsonEncode({'updatedAt': DateTime.now().toUtc().toIso8601String()}),
    );
    await expectLater(
      AutomaticCollaboration.prepare(
        source: source,
        support: Directory(p.join(temp.path, 'client')),
      ),
      throwsA(isA<StateError>()),
    );
    expect(await AutomaticCollaboration.association(source).exists(), isFalse);
    expect(await DocumentStore().currentFingerprint(source.path), before);
  });

  test('共同編集開始後に原本が書き換わったら無言で参加しない', () async {
    final (temp, source, before) = await fixture();
    addTearDown(() => temp.delete(recursive: true));
    await AutomaticCollaboration.prepare(
      source: source,
      support: Directory(p.join(temp.path, 'first')),
    );
    await source.writeAsBytes([1, 2, 3, 4], flush: true);
    expect(
      await DocumentStore().currentFingerprint(source.path),
      isNot(before),
    );
    await expectLater(
      AutomaticCollaboration.prepare(
        source: source,
        support: Directory(p.join(temp.path, 'second')),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('偽造された共同編集情報・不一致の鍵を受け付けない', () async {
    final (temp, source, before) = await fixture();
    addTearDown(() => temp.delete(recursive: true));
    final sidecar = AutomaticCollaboration.association(source);
    await sidecar.writeAsString(
      jsonEncode({
        'format': 'TNote automatic collaboration v1',
        'source_sha256': before,
        'room': 'a' * 64,
        'join_key': CollaborationSession.newKey(),
      }),
    );
    await expectLater(
      AutomaticCollaboration.prepare(
        source: source,
        support: Directory(p.join(temp.path, 'second')),
      ),
      throwsA(isA<FormatException>()),
    );
  });
  Future<CollaborationSession> open(Directory support, AutomaticRoom room) =>
      CollaborationSession.open(
        support: room.cacheIn(
          Directory(p.join(support.path, 'collaboration-v1')),
        ),
        exchange: room.directory,
        code: room.key,
      );

  // The two directories have no shared filesystem visibility. Replicate only
  // immutable blocks and intentionally deliver them out of order without the index.
  Future<void> deliver(Directory from, Directory to) async {
    final blocks = await from
        .list()
        .where((f) => f.path.endsWith('.op'))
        .toList();
    for (final file in blocks.reversed) {
      final destination = File(p.join(to.path, p.basename(file.path)));
      if (!await destination.exists()) {
        await File(file.path).copy(destination.path);
      }
    }
  }

  test('三つの未同期の初回参加が同じ履歴に合流し、切断中の再起動・最新本文の復元ができる', () async {
    final temp = await Directory.systemTemp.createTemp('tnote-mirrors-');
    addTearDown(() => temp.delete(recursive: true));
    final devices = [
      for (var i = 0; i < 3; i++) Directory(p.join(temp.path, 'local$i')),
    ];
    final originals = [
      for (var i = 0; i < 3; i++)
        File(
          p.join(
            temp.path,
            'cloud$i',
            i == 2 ? 'カ\u3099イド.tnote' : 'ガイド.tnote',
          ),
        ),
    ];
    for (final f in originals) {
      await f.parent.create();
    }
    final doc = NoteDocument.create(1), tab = doc.activeTab;
    tab.text = '頭削中尾\n';
    tab.delta = [
      {
        'insert': '頭削中尾',
        'attributes': {'italic': true, 'bold': true, 'size': '24'},
      },
      {'insert': '\n'},
    ];
    final store = DocumentStore();
    await store.save(doc, originals.first.path, create: true);
    for (final f in originals.skip(1)) {
      await originals.first.copy(f.path);
    }
    final rooms = await Future.wait([
      for (var i = 0; i < 3; i++)
        AutomaticCollaboration.prepare(
          source: originals[i],
          support: devices[i],
        ),
    ]);
    expect(rooms.map((r) => r.room).toSet(), hasLength(1));
    final sidecars = await Future.wait(
      originals.map(
        (f) => AutomaticCollaboration.association(f).readAsString(),
      ),
    );
    expect(sidecars.toSet().length, 1);
    expect(sidecars.first.contains(rooms.first.key), isFalse);
    final sessions = await Future.wait([
      for (var i = 0; i < 3; i++) open(devices[i], rooms[i]),
    ]);
    addTearDown(() async {
      for (final session in sessions) {
        await session.shutdown();
      }
    });
    for (final s in sessions) {
      expect(s.replica.content(tab.id), tab.delta);
    }

    // Both connected clients insert at the same position. The disconnected
    // one removes a neighbouring original character, then modifies a distant spot.
    for (var i = 0; i < 2; i++) {
      sessions[i].edit(
        (r) => r.applyText(tab.id, [
          {'retain': 1},
          {'insert': i == 0 ? '甲' : '乙'},
        ]),
      );
      await sessions[i].sync();
    }
    final detached = await originals[2].parent.rename(
      p.join(temp.path, 'detached'),
    );
    sessions[2].edit(
      (r) => r.applyText(tab.id, [
        {'retain': 1},
        {'delete': 1},
        {'retain': 2},
        {'insert': '丙'},
      ]),
    );
    await sessions[2].sync();
    expect(sessions[2].status, contains('端末内に保存'));
    await sessions[2].shutdown();
    final offline = await AutomaticCollaboration.openOffline(
      source: originals[2],
      support: devices[2],
    );
    expect(offline, isNotNull);
    sessions[2] = await open(devices[2], offline!);
    expect(sessions[2].replica.body(tab.id).toString(), '頭中尾丙\n');
    expect(await rooms[2].directory.exists(), isFalse);
    await detached.rename(originals[2].parent.path);
    await sessions[2].sync();
    for (final from in sessions.reversed) {
      for (final to in sessions.where((to) => to != from)) {
        await deliver(from.directory, to.directory);
      }
    }
    for (final session in sessions) {
      await session.sync();
    }
    final text = sessions.first.replica.body(tab.id).toString();
    expect(text, matches(RegExp(r'^頭(甲乙|乙甲)中尾丙\n$')));
    final delta = sessions.first.replica.content(tab.id);
    for (var i = 0; i < 3; i++) {
      final s = sessions[i];
      expect(s.replica.body(tab.id).toString(), text);
      expect(s.replica.content(tab.id), delta);
      expect(s.replica.ids(s.replica.titles), [doc.id]);
      expect(s.replica.ids(s.replica.tabs(doc.id)), [tab.id]);
      expect(
        s.restoreAt(s.history.first.sequence).documents.first.activeTab.text,
        text,
      );
      await s.shutdown();
      final again = await AutomaticCollaboration.prepare(
        source: originals[i],
        support: devices[i],
      );
      sessions[i] = await open(devices[i], again);
      expect(sessions[i].replica.content(tab.id), delta);
      final backup = p.join(
        devices[i].path,
        'collaboration-v1',
        'auto-migration',
        rooms[i].room,
        'original.tnote',
      );
      expect(
        await store.currentFingerprint(backup),
        await store.currentFingerprint(originals[i].path),
      );
    }
    final exported = p.join(temp.path, '復元した最新版.tnote');
    final latest = sessions.first.replica.workspace();
    await store.saveWorkspace(
      latest.documents,
      latest.activeDocumentId,
      exported,
      create: true,
    );
    expect((await store.open(exported)).activeTab.delta, delta);
  });

  test('名前が同じ別原本・別名の複製は別室、フォルダーごとのローカル履歴も独立する', () async {
    final (temp, source, _) = await fixture();
    addTearDown(() => temp.delete(recursive: true));
    final local = Directory(p.join(temp.path, 'client'));
    Future<AutomaticRoom> prepare(File f) =>
        AutomaticCollaboration.prepare(source: f, support: local);
    final a = await prepare(source);
    final sameName = File(p.join(temp.path, 'other', p.basename(source.path)));
    await sameName.parent.create();
    await DocumentStore().save(
      NoteDocument.create(1),
      sameName.path,
      create: true,
    );
    expect((await prepare(sameName)).room == a.room, isFalse);
    final renamedCopy = await source.copy(
      p.join(source.parent.path, '複製.tnote'),
    );
    expect((await prepare(renamedCopy)).room == a.room, isFalse);
    final sameNameCopy = File(
      p.join(temp.path, 'third', p.basename(source.path)),
    );
    await sameNameCopy.parent.create();
    await source.copy(sameNameCopy.path);
    final twin = await prepare(sameNameCopy);
    expect(twin.cacheScope == a.cacheScope, isFalse);
    final firstSession = await open(local, a),
        twinSession = await open(local, twin);
    addTearDown(firstSession.shutdown);
    addTearDown(twinSession.shutdown);
    final id = firstSession.replica.workspace().documents.first.activeTabId;
    firstSession.edit(
      (r) => r.applyText(id, [
        {'insert': '別フォルダー'},
      ]),
    );
    await firstSession.sync();
    await twinSession.sync();
    expect(twinSession.replica.body(id).toString(), '\n');
    final renamed = await source.rename(
      p.join(source.parent.path, '移動後.tnote'),
    );
    await AutomaticCollaboration.association(source)
        .rename(AutomaticCollaboration.association(renamed).path);
    expect((await prepare(renamed)).room, a.room);
  });

  test('v1のランダム鍵・履歴を引き継ぎ、別roomのsidecarが届いたら履歴を保護する', () async {
    final (temp, source, fingerprint) = await fixture();
    addTearDown(() => temp.delete(recursive: true));
    final local = Directory(p.join(temp.path, 'client'));
    final key = CollaborationSession.newKey();
    final room = CollaborationSession.roomId(base64Url.decode(key));
    final old = await CollaborationSession.open(
      support: Directory(p.join(local.path, 'collaboration-v1')),
      exchange: source.parent,
      code: key,
    );
    final workspace = await DocumentStore().openWorkspace(source.path);
    final id = workspace.documents.first.activeTabId;
    old.edit((r) => r.seed(workspace));
    old.edit(
      (r) => r.applyText(id, [
        {'insert': '未送信'},
      ]),
    );
    await old.shutdown();
    final sidecar = AutomaticCollaboration.association(source);
    final oldRecord = jsonEncode({
      'format': 'TNote automatic collaboration v1',
      'source_sha256': fingerprint,
      'room': room,
      'join_key': key,
    });
    await sidecar.writeAsString(oldRecord, flush: true);
    final joined = await AutomaticCollaboration.prepare(
      source: source,
      support: local,
    );
    expect(joined.cacheScope, isNull);
    expect(joined.key == key, isTrue);
    expect(await sidecar.readAsString() == oldRecord, isTrue);
    final retained = await open(local, joined);
    addTearDown(retained.shutdown);
    expect(retained.replica.body(id).toString(), '未送信\n');
    await sidecar.rename(p.join(temp.path, 'v1-backup.json'));
    await expectLater(
      AutomaticCollaboration.prepare(source: source, support: local),
      throwsStateError,
    );
    expect(await sidecar.exists(), isFalse);
    expect(retained.replica.body(id).toString(), '未送信\n');
  });
}
