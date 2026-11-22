import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tnote/models/document.dart';
import 'package:tnote/services/document_store.dart';
import 'package:tnote/services/collaboration_session.dart';
import 'package:tnote/services/collaboration_link.dart';

void main() {
  test('隔離した実機受入メモを作成', () async {
    final root = Directory(Platform.environment['TNOTE_ACCEPTANCE_EXCHANGE']!);
    final state = Directory(Platform.environment['TNOTE_ACCEPTANCE_STATE']!);
    if (!p.basename(root.path).startsWith('TNote-accept-') ||
        !await root.exists() ||
        !await root.list().isEmpty) {
      throw StateError('Expected empty acceptance share');
    }
    await state.create(recursive: true);
    final code = CollaborationSession.newKey();
    final keyFile = File(p.join(state.path, 'fixture.key'));
    await keyFile.create(exclusive: true);
    await keyFile.writeAsString(code, flush: true);
    final s = await CollaborationSession.open(
      support: state,
      exchange: root,
      code: code,
    );
    try {
      final first = NoteDocument.create(1)..customName = '作業';
      first.activeTab.delta = [
        {'insert': 'TNote-Accept\n'},
      ];
      first.activeTab.text = 'TNote-Accept\n';
      await s.createExchange();
      s.edit((r) {
        r.seed(StoredWorkspace(documents: [first], activeDocumentId: first.id));
        r.document.getMap('workspace')['name'] = 'TNote-Accept';
      });
      await s.sync();
      final link = await CollaborationLink.create(root, 'TNote-Accept', s.room);
      await link.rename(p.join(root.path, 'TNote-Accept.tnote'));
      final second = await CollaborationSession.open(
        support: Directory(p.join(state.path, 'observer')),
        exchange: root,
        code: code,
      );
      try {
        await second.sync();
        expect(
          second.replica.workspace().documents.first.activeTab.text,
          'TNote-Accept\n',
        );
      } finally {
        await second.shutdown();
      }
    } finally {
      await s.shutdown();
    }
  });
}
