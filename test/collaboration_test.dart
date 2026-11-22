import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tnote/models/document.dart';
import 'package:tnote/services/document_store.dart';
import 'package:tnote/services/collaboration_session.dart';
import 'package:tnote/services/collaboration_link.dart';
import 'package:tnote/services/collaboration_replica.dart';
import 'package:tnote/widgets/note_editor.dart';

void main() {
  test('順序逆転・二重受信で本文と書式が一致し、削除済み項目を勝手に戻さない', () {
    final a = CollaborationReplica(), b = CollaborationReplica();
    addTearDown(a.close);
    addTearDown(b.close);
    final doc = NoteDocument.create(1), id = doc.activeTab.id;
    final seed = a.change(
      () => a.seed(StoredWorkspace(documents: [doc], activeDocumentId: doc.id)),
    );
    final insert = a.change(
      () => a.applyText(id, [
        {'insert': '日本😀'},
      ]),
    );
    final format = a.change(
      () => a.applyText(id, [
        {
          'retain': 2,
          'attributes': {'bold': true},
        },
      ]),
    );
    final removal = a.change(() => a.meta(id)['deleted'] = true);
    for (final block in [
      removal,
      format,
      insert,
      insert,
      seed,
      format,
      removal,
    ]) {
      b.receive(block);
    }
    expect(b.content(id), a.content(id));
    expect(b.ids(b.tabs(doc.id)), isEmpty);
  });
  testWidgets('共同メモの遠隔差分を表示し、元に戻す操作は自分の入力だけに適用する', (tester) async {
    final key = GlobalKey<NoteEditorState>();
    final tab = NoteTab.create('試験');
    final writes = <List<dynamic>>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        home: Scaffold(
          body: NoteEditor(
            key: key,
            tab: tab,
            readOnly: false,
            fontSize: 18,
            onOperation: writes.add,
            onChanged: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<QuillEditor>(find.byType(QuillEditor))
        .controller;
    controller.replaceText(
      0,
      0,
      '自分',
      const TextSelection.collapsed(offset: 2),
    );
    await tester.pump();
    expect(writes.length, 1);
    key.currentState!.receiveOperations([
      {'insert': '相手'},
    ]);
    await tester.pump();
    expect(controller.document.toPlainText(), '相手自分\n');
    expect(controller.selection.extentOffset, 4);
    expect(writes.length, 1);
    controller.undo();
    await tester.pump();
    expect(controller.document.toPlainText(), '相手\n');
    controller.redo();
    await tester.pump();
    expect(controller.document.toPlainText(), '相手自分\n');
  });

  test('共同編集の.tnoteには識別子だけを記録し、旧版はファイルを変更できない', () async {
    final dir = await Directory.systemTemp.createTemp('tnote-link-');
    addTearDown(() => dir.delete(recursive: true));
    final id = 'a' * 64;
    final link = await CollaborationLink.create(dir, '仕事', id);
    expect(await CollaborationLink.read(link.path), id);
    final before = fingerprint(link.path);
    await expectLater(DocumentStore().open(link.path), throwsA(anything));
    expect(fingerprint(link.path), before);
    expect((await CollaborationLink.create(dir, '仕事', id)).path, link.path);
  });
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
