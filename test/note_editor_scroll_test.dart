import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:tnote/app/app.dart';
import 'package:tnote/models/document.dart';
import 'package:tnote/services/document_controller.dart';
import 'package:tnote/services/document_store.dart';
import 'package:tnote/services/recovery_store.dart';
import 'package:tnote/widgets/note_editor.dart';

void main() {
  testWidgets('長文でコピー・背景更新・端のドラッグ選択を行う', (tester) async {
    final directory = Directory.systemTemp.createTempSync('tnote-editor-test-');
    final state = DocumentController(
      store: DocumentStore(),
      recovery: RecoveryStore(directory),
      startTimers: false,
    );
    final clipboard = _mockClipboard(tester);
    addTearDown(() {
      state.dispose();
      directory.deleteSync(recursive: true);
    });
    final text = List.generate(80, (i) => '$i 日本語の長文です。📝' * 5).join('\n');
    final doc = state.create();
    state.editRich(doc, doc.activeTab, [
      {'insert': '$text\n'},
    ], '$text\n');
    await tester.pumpWidget(TNoteApp(controller: state));
    await tester.pump(const Duration(milliseconds: 850));
    await tester.pumpAndSettle();
    final editorFinder = find.byType(QuillEditor);
    final editor = tester.widget<QuillEditor>(editorFinder);
    final position = editor.scrollController.position;
    expect(position.maxScrollExtent, greaterThan(1500));
    expect(position.pixels, 0);
    final box = tester.getRect(editorFinder);
    final middle = position.maxScrollExtent / 2;
    const selection = TextSelection(baseOffset: 3, extentOffset: 21);
    editor.controller.updateSelection(selection, ChangeSource.local);
    await tester.pumpAndSettle();
    position.jumpTo(middle);
    await tester.pumpAndSettle();

    await _copy(tester);
    await tester.pumpAndSettle();
    expect(clipboard(), text.substring(selection.start, selection.end));
    expect(editor.controller.selection, selection);
    expect(position.pixels, middle);

    final right = await tester.startGesture(
      box.center,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await right.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('コピー').last);
    await tester.pumpAndSettle();
    state.notifyListeners();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(clipboard(), text.substring(selection.start, selection.end));
    expect(editor.controller.selection, selection);
    expect(position.pixels, middle);

    await _expectFullDragAndCopy(tester, editor, text, clipboard);
    // Search explicitly moves the reading position to the matched text.
    await tester.tap(find.byTooltip('検索'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    await tester.enterText(find.descendant(of: dialog, matching: find.byType(TextField)), '79 日本語');
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: dialog, matching: find.text(doc.activeTab.name)).first);
    await tester.pumpAndSettle();
    expect(editor.controller.selection.textInside(text), '79 日本語');
    expect(position.pixels, greaterThan(middle));
    expect(tester.takeException(), isNull);
  }, variant: _desktopPlatforms);

  testWidgets('共同編集の追記・削除で閲覧中の行と逆向き選択を保つ', (tester) async {
    final text = List.generate(100, (i) => '行$i の本文📝').join('\n');
    final key = GlobalKey<NoteEditorState>();
    final tab = NoteTab(
      id: 'isolated',
      name: '検証',
      text: text,
      createdAt: '',
      updatedAt: '',
    );
    final local = <List<dynamic>>[];
    final clipboard = _mockClipboard(tester);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [FlutterQuillLocalizations.delegate],
        home: Scaffold(
          body: NoteEditor(
            key: key,
            tab: tab,
            fontSize: 18,
            readOnly: false,
            onChanged: (_, _) {},
            onOperation: local.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final finder = find.byType(QuillEditor);
    final editor = tester.widget<QuillEditor>(finder);
    final position = editor.scrollController.position;
    final renderer = editor.config.editorKey!.currentState!.renderEditor;
    double caretY(int offset) => renderer
        .localToGlobal(
          renderer.getLocalRectForCaret(TextPosition(offset: offset)).topLeft,
        )
        .dy;
    final anchor = text.indexOf('行50 ');
    final start = text.indexOf('行2 ');
    final end = text.indexOf('行4 ');
    editor.controller.updateSelection(
      TextSelection(baseOffset: end, extentOffset: start),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();
    position.jumpTo(
      caretY(anchor) - tester.getRect(finder).top - 80 + position.pixels,
    );
    await tester.pumpAndSettle();
    final originalY = caretY(anchor);
    const prefix = '共同編集からの追記\nもう一行\n';
    const boundary = '選択対象の前\n';
    key.currentState!.receiveOperations([
      {'insert': prefix},
    ]);
    key.currentState!.receiveOperations([
      {'retain': start + prefix.length},
      {'insert': boundary},
    ]);
    await tester.pumpAndSettle();
    final shift = prefix.length + boundary.length;
    expect(caretY(anchor + shift), closeTo(originalY, 1));
    expect(
      editor.controller.selection,
      TextSelection(baseOffset: end + shift, extentOffset: start + shift),
    );
    expect(
      editor.controller.selection.textInside(
        editor.controller.document.toPlainText(),
      ),
      text.substring(start, end),
    );
    key.currentState!.receiveOperations([
      {'delete': prefix.length},
    ]);
    await tester.pumpAndSettle();
    expect(caretY(anchor + boundary.length), closeTo(originalY, 1));
    expect(local, isEmpty);

    final body = editor.controller.document.toPlainText();
    await _expectFullDragAndCopy(
      tester,
      editor,
      body.substring(0, body.length - 1),
      clipboard,
    );

    // A stationary edge drag ceases immediately on focus loss or cancellation.
    final box = tester.getRect(finder);
    for (final loseFocus in [true, false]) {
      editor.focusNode.requestFocus();
      await tester.pumpAndSettle();
      final drag = await tester.startGesture(
        box.center,
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(Offset(box.center.dx, box.bottom - 1));
      await tester.pump(const Duration(milliseconds: 32));
      expect(key.currentState!.inputInProgress, isTrue);
      if (loseFocus) {
        editor.focusNode.unfocus();
        await tester.pump();
      } else {
        await drag.cancel();
      }
      expect(key.currentState!.inputInProgress, isFalse);
      await tester.pumpAndSettle();
      final stopped = position.pixels;
      await tester.pump(const Duration(milliseconds: 150));
      expect(position.pixels, stopped);
      if (loseFocus) await drag.up();
    }
    // The platform edits the composing range before the user commits the kanji.
    editor.focusNode.requestFocus();
    await tester.pumpAndSettle();
    final prior = editor.controller.document.toPlainText();
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: 'へんかん$prior',
        selection: const TextSelection.collapsed(offset: 4),
        composing: const TextRange(start: 0, end: 4),
      ),
    );
    await tester.pump();
    expect(key.currentState!.inputInProgress, isTrue);
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: '変換$prior',
        selection: const TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    expect(key.currentState!.inputInProgress, isFalse);
    expect(editor.controller.document.toPlainText(), '変換$prior');
    expect(tester.takeException(), isNull);
  }, variant: _desktopPlatforms);
}

const _desktopPlatforms = TargetPlatformVariant({
  TargetPlatform.windows,
  TargetPlatform.macOS,
});

Future<void> _copy(WidgetTester tester) async {
  final modifier = defaultTargetPlatform == TargetPlatform.macOS
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

String Function() _mockClipboard(WidgetTester tester) {
  var clipboard = '';
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      clipboard = (call.arguments as Map)['text'] as String;
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return () => clipboard;
}

Future<void> _expectFullDragAndCopy(
  WidgetTester tester,
  QuillEditor editor,
  String text,
  String Function() clipboard,
) async {
  final position = editor.scrollController.position;
  final box = tester.getRect(find.byType(QuillEditor));
  position.jumpTo(0);
  await tester.pumpAndSettle();
  final renderer = editor.config.editorKey!.currentState!.renderEditor;
  Offset caret(int offset) => renderer.localToGlobal(
    renderer.getLocalRectForCaret(TextPosition(offset: offset)).centerLeft,
  );
  final startPoint = Offset(box.left + 24.5, caret(0).dy);
  expect(
    box.contains(startPoint),
    isTrue,
    reason: '先頭のクリック位置 $startPoint ／ $box',
  );
  expect(renderer.getPositionForOffset(startPoint).offset, 0);
  final drag = await tester.startGesture(
    startPoint,
    kind: PointerDeviceKind.mouse,
  );
  await drag.moveTo(Offset(box.left + 70, box.top + 75));
  await tester.pump();
  await drag.moveTo(Offset(box.left + 80, box.bottom - 2));
  await tester.pump();
  for (var i = 0; i < 600 && position.pixels < position.maxScrollExtent; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(position.pixels, position.maxScrollExtent);
  expect(editor.controller.selection.extentOffset, text.length);
  expect(editor.controller.selection.baseOffset, 0);
  await drag.up();
  await tester.pump(const Duration(milliseconds: 300));
  expect(position.pixels, position.maxScrollExtent);
  await _copy(tester);
  expect(clipboard(), text);

  final endPoint = Offset(box.right - 25, caret(text.length).dy);
  expect(box.contains(endPoint), isTrue);
  expect(renderer.getPositionForOffset(endPoint).offset, text.length);
  final reverse = await tester.startGesture(
    endPoint,
    kind: PointerDeviceKind.mouse,
  );
  await reverse.moveTo(Offset(box.left + 70, box.bottom - 80));
  await tester.pump();
  await reverse.moveTo(Offset(box.left + 70, box.top + 2));
  await tester.pump();
  for (var i = 0; i < 600 && position.pixels > 0; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(position.pixels, 0);
  expect(editor.controller.selection.extentOffset, 0);
  expect(editor.controller.selection.baseOffset, text.length);
  await reverse.up();
  await tester.pumpAndSettle();
  await _copy(tester);
  expect(clipboard(), text);
}
