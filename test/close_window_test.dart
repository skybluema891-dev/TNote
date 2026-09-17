import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tnote/app/app.dart';
import 'package:tnote/models/document.dart';
import 'package:tnote/screens/workspace_screen.dart';
import 'package:tnote/services/document_controller.dart';
import 'package:tnote/services/document_store.dart';
import 'package:tnote/services/recovery_store.dart';
import 'package:tnote/services/user_error.dart';

class MemoryRecovery extends RecoveryStore {
  MemoryRecovery() : super(Directory.systemTemp);
  @override
  Future<void> write(NoteDocument doc) async {}
  @override
  Future<void> remove(NoteDocument doc) async {}
}

void main() {
  test('内部例外を日本語の案内へ変換する', () {
    for (final error in [
      StateError('Concurrent modification during iteration'),
      const FileSystemException('Access denied'),
      const FormatException('Invalid document'),
    ]) {
      expect(userError(error), isNot(matches(RegExp('[A-Za-z]'))));
    }
    expect(userError(StateError('保存前に文書を閉じることはできません。')), '保存前に文書を閉じることはできません。');
  });

  testWidgets('未保存の複数タイトルを一度だけ確認して終了する', (tester) async {
    final controller = DocumentController(
      store: DocumentStore(),
      recovery: MemoryRecovery(),
      startTimers: false,
    );
    addTearDown(controller.dispose);
    controller.create();
    controller.create();
    await tester.pumpWidget(TNoteApp(controller: controller));
    final dynamic workspace = tester.state(find.byType(WorkspaceScreen));
    workspace.onWindowClose();
    await tester.pumpAndSettle();
    expect(find.text('ファイルを保存しますか？'), findsOneWidget);
    expect(find.text('保存しない'), findsOneWidget);
    await tester.tap(find.text('保存しない'));
    await tester.pumpAndSettle();
    expect(controller.documents, isEmpty);
    expect(find.text('ファイルを保存しますか？'), findsNothing);
    expect(find.textContaining('処理を完了できません'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('起動時に復元確認を表示せず古い下書きを破棄する', (tester) async {
    final old = NoteDocument.create(1);
    old.activeTab.text = '以前の下書き';
    old.changed();
    final controller = DocumentController(
      store: DocumentStore(),
      recovery: MemoryRecovery(),
      startTimers: false,
    );
    controller.recoverable = [old];
    addTearDown(controller.dispose);
    await tester.pumpWidget(TNoteApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.textContaining('復元しますか？'), findsNothing);
    expect(controller.documents, isEmpty);
    expect(controller.recoverable, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
