import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:tnote/app/app.dart';
import 'package:tnote/services/document_controller.dart';
import 'package:tnote/services/document_store.dart';
import 'package:tnote/services/recovery_store.dart';

void main() {
  testWidgets('長文でコピー・背景更新・端のドラッグ選択を行う', (tester) async {
    final directory = Directory.systemTemp.createTempSync('tnote-editor-test-');
    final state = DocumentController(
      store: DocumentStore(),
      recovery: RecoveryStore(directory),
      startTimers: false,
    );
    var clipboard = '';
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      state.dispose();
      directory.deleteSync(recursive: true);
    });
    final text = List.generate(80, (i) => '$i 日本語の長文です。' * 5).join('\n');
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

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(clipboard, text.substring(selection.start, selection.end));
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
    expect(clipboard, text.substring(selection.start, selection.end));
    expect(editor.controller.selection, selection);
    expect(position.pixels, middle);

    position.jumpTo(0);
    await tester.pumpAndSettle();
    final drag = await tester.startGesture(
      Offset(box.left + 60, box.top + 35),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveTo(Offset(box.left + 70, box.top + 75));
    await tester.pump();
    await drag.moveTo(Offset(box.left + 80, box.bottom - 2));
    await tester.pump();
    for (
      var i = 0;
      i < 600 && position.pixels < position.maxScrollExtent;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(position.pixels, position.maxScrollExtent);
    expect(editor.controller.selection.extentOffset, text.length);
    final anchor = editor.controller.selection.baseOffset;
    expect(anchor, lessThan(100));
    await drag.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(position.pixels, position.maxScrollExtent);

    final reverse = await tester.startGesture(
      Offset(box.left + 60, box.bottom - 40),
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
    expect(editor.controller.selection.baseOffset, greaterThan(anchor));
    await reverse.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));
}
