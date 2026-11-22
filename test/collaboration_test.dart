import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tnote/models/document.dart';
import 'package:tnote/services/document_store.dart';
import 'package:tnote/services/collaboration_session.dart';

void main() {
  test('三端末で本文・書式・順序を統合し、オフライン再起動と削除から復元する', () async {
    final temp = await Directory.systemTemp.createTemp('tnote-collab-');
    addTearDown(() => temp.delete(recursive: true));
    final shared = await Directory(p.join(temp.path, 'shared')).create();
    final key = CollaborationSession.newKey();
    Future<CollaborationSession> open(String device) =>
        CollaborationSession.open(
          support: Directory(p.join(temp.path, device)),
          exchange: shared,
          code: key,
        );
    final a = await open('a'), b = await open('b');
    var c = await open('c');
    final doc = NoteDocument.create(1);
    final tab = doc.activeTab.id;
    final seed = StoredWorkspace(documents: [doc], activeDocumentId: doc.id);
    await a.createExchange();
    a.edit((r) => r.seed(seed));
    await a.sync();
    await b.sync();
    await c.sync();
    a.edit(
      (r) => r.applyText(tab, [
        {
          'insert': '日😀',
          'attributes': {'bold': true},
        },
      ]),
    );
    b.edit(
      (r) => r.applyText(tab, [
        {'insert': '本'},
      ]),
    );
    c.edit(
      (r) => r.applyText(tab, [
        {'insert': '語'},
      ]),
    );
    await c.shutdown();
    c = await open('c');
    await a.sync();
    await b.sync();
    await c.sync();
    await a.sync();
    await b.sync();
    for (final s in [a, b, c]) {
      expect(s.replica.content(tab), a.replica.content(tab));
      expect(s.replica.body(tab).toString(), contains('😀'));
      expect(s.replica.body(tab).toString().runes.length, 5);
    }
    a.edit(
      (r) => r.applyText(tab, [
        {
          'retain': 1,
          'attributes': {'underline': true},
        },
      ]),
    );
    b.edit(
      (r) => r.applyText(tab, [
        {'delete': 1},
      ]),
    );
    c.edit((r) => r.meta(tab)['deleted'] = true);
    await c.sync();
    await b.sync();
    await a.sync();
    await c.sync();
    await b.sync();
    for (final s in [a, b, c]) {
      expect(s.replica.ids(s.replica.tabs(doc.id)), isEmpty);
      expect(s.replica.content(tab), a.replica.content(tab));
    }
    c.edit((r) => r.meta(tab)['deleted'] = false);
    await c.sync();
    await a.sync();
    await b.sync();
    expect(a.replica.ids(a.replica.tabs(doc.id)), [tab]);
    expect(a.replica.content(tab), c.replica.content(tab));
    final payloads = await a.directory
        .list()
        .where((f) => f.path.endsWith('.op'))
        .length;
    for (final s in [a, b, c]) {
      await s.sync();
      await s.shutdown();
    }
    expect(await a.directory.list().length, payloads);
  });

  test('移行バックアップから元のID・書式・順序を復元できる', () async {
    final dir = await Directory.systemTemp.createTemp('tnote-migrate-');
    addTearDown(() => dir.delete(recursive: true));
    final a = NoteDocument.create(1), b = NoteDocument.create(2);
    a.activeTab.delta = [
      {
        'insert': '仕事',
        'attributes': {'bold': true, 'size': '22'},
      },
      {'insert': '\n'},
    ];
    final store = DocumentStore(),
        src = p.join(dir.path, 'a.tnote'),
        copy = p.join(dir.path, 'backup.tnote');
    await store.saveWorkspace([b, a], a.id, src, create: true);
    final before = fingerprint(src);
    await store.backupWorkspace(src, copy);
    final saved = await store.openWorkspace(copy);
    final session = await CollaborationSession.open(
      support: Directory(p.join(dir.path, 'local')),
      exchange: dir,
      code: CollaborationSession.newKey(),
    );
    session.edit((r) => r.seed(saved));
    final restored = session.replica.workspace();
    expect(restored.documents.map((n) => n.id), [b.id, a.id]);
    expect(restored.activeDocumentId, a.id);
    expect(restored.documents.last.activeTab.delta, a.activeTab.delta);
    expect(fingerprint(src), before);
    await session.shutdown();
  });
}
