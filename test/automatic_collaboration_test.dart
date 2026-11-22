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
    return (temp, source, await DocumentStore().currentFingerprint(source.path));
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
    expect(rooms[0].key, rooms[1].key);
    expect(rooms[0].link['path'], source.parent.path);
    expect(rooms[1].link['autoCode'], rooms[0].key);
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
    expect(reopened.key, rooms.first.key);
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
    expect(await DocumentStore().currentFingerprint(source.path), isNot(before));
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
    await sidecar.writeAsString(jsonEncode({
      'format': 'TNote automatic collaboration v1',
      'source_sha256': before,
      'room': 'a' * 64,
      'join_key': CollaborationSession.newKey(),
    }));
    await expectLater(
      AutomaticCollaboration.prepare(
        source: source,
        support: Directory(p.join(temp.path, 'second')),
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
