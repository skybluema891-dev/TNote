import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter/services.dart';
import 'package:tnote/app/app.dart';
import 'package:tnote/services/document_controller.dart';
import 'package:tnote/services/document_store.dart';
import 'package:tnote/services/recovery_store.dart';

void main() {
  testWidgets('文書作成、日本語入力、タブ切替、削除キャンセル、狭い画面', (tester) async {
    var clipboardText = '';
    var clipboardFailures = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          if (clipboardFailures > 0) {
            clipboardFailures--;
            throw PlatformException(code: 'clipboard_busy');
          }
          return <String, dynamic>{'text': clipboardText};
        }
        if (call.method == 'Clipboard.setData') {
          clipboardText =
              (call.arguments as Map<dynamic, dynamic>)['text'] as String? ??
              '';
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final directory = Directory.systemTemp.createTempSync('tnote-widget-');
    final controller = DocumentController(
      store: DocumentStore(),
      recovery: RecoveryStore(directory),
      startTimers: false,
    );
    addTearDown(() {
      controller.dispose();
      directory.deleteSync(recursive: true);
    });
    await tester.pumpWidget(TNoteApp(controller: controller));
    expect(find.text('新しいファイル'), findsOneWidget);
    await tester.tap(find.text('新しいファイル'));
    await tester.pump();
    final doc = controller.current!;
    doc.path = '${directory.path}${Platform.pathSeparator}仕事ファイル.tnote';
    controller.notifyListeners();
    await tester.pump();
    expect(find.text('仕事ファイル *'), findsOneWidget);
    final fileTitle = tester.widget<Text>(find.text('仕事ファイル *'));
    expect(fileTitle.style?.fontSize, 26);
    expect(fileTitle.style?.fontWeight, FontWeight.w700);
    expect(find.byTooltip('タイトルを追加'), findsOneWidget);
    expect(find.byTooltip('取扱説明'), findsOneWidget);
    await tester.tap(find.byTooltip('取扱説明'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('guide-title')), findsOneWidget);
    expect(find.text('タイトルを作る・ファイルを開く'), findsOneWidget);
    await tester.tap(find.text('閉じる').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('ファイル'));
    await tester.pumpAndSettle();
    expect(find.text('上書き保存'), findsOneWidget);
    expect(find.text('ファイルに保存'), findsOneWidget);
    await tester.ensureVisible(find.text('設定'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('設定'));
    await tester.pumpAndSettle();
    expect(find.text('標準フォント'), findsNothing);
    expect(find.text('簡単な取扱説明'), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(find.byType(QuillEditor), findsOneWidget);
    for (final tooltip in [
      '元に戻す',
      'やり直す',
      '貼り付け',
      '文字サイズ',
      '太字',
      '斜体',
      '下線',
      '文字の色',
      '背景の色',
      '書式を解除',
      '見出し',
      '番号付き一覧',
      '箇条書き',
    ]) {
      expect(find.byTooltip(tooltip), findsOneWidget);
    }
    for (final englishTooltip in ['Undo', 'Redo', 'Font size', 'Bold']) {
      expect(find.byTooltip(englishTooltip), findsNothing);
    }
    await tester.tap(find.byTooltip('文字サイズの一覧'));
    await tester.pumpAndSettle();
    expect(find.text('8'), findsOneWidget);
    expect(find.text('72'), findsOneWidget);
    await tester.tap(find.text('16').last);
    await tester.pumpAndSettle();
    expect(find.byTooltip('フォント'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('font-size-field')), '37');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('37'), findsOneWidget);
    await tester.tap(find.byTooltip('文字の色'));
    await tester.pumpAndSettle();
    expect(find.text('文字の色'), findsOneWidget);
    expect(find.byTooltip('濃い赤'), findsOneWidget);
    expect(find.byTooltip('薄い青'), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(
      Localizations.localeOf(tester.element(find.byType(QuillEditor))),
      const Locale('ja'),
    );
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final editorContext = tester.element(find.byType(QuillEditor));
    expect(
      editor.config.customStyles!.paragraph!.style.color,
      Theme.of(editorContext).colorScheme.onSurface,
    );
    await tester.tapAt(
      tester.getTopLeft(find.byType(QuillEditor)) + const Offset(40, 35),
    );
    await tester.pump();
    expect(editor.focusNode.hasFocus, isTrue);
    for (final text in ['あ', 'あい', 'あいう', '日本語', '日本語\n二行目']) {
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '$text\n',
          selection: TextSelection.collapsed(offset: text.length),
        ),
      );
      await tester.idle();
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: '入力: $text / 文書: ${editor.controller.document.toPlainText()}',
      );
      expect(doc.activeTab.text, '$text\n');
      expect(editor.focusNode.hasFocus, isTrue);
    }
    const firstText = '日本語の文章\n旋盤のメモ\n';
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: firstText,
        selection: TextSelection.collapsed(offset: firstText.length - 1),
      ),
    );
    await tester.idle();
    await tester.pump();
    expect(doc.activeTab.text, contains('日本語の文章\n旋盤のメモ'));
    clipboardText = '品名\t数量\r\n部品A\t10\r\n';
    clipboardFailures = 2;
    await tester.tap(find.byTooltip('貼り付け'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.idle();
    await tester.pump();
    await tester.idle();
    await tester.pump();
    expect(doc.activeTab.text, contains('品名\t数量\n部品A\t10\n'));
    clipboardText = '右クリックから貼り付け';
    final editorMenuGesture = await tester.startGesture(
      tester.getCenter(find.byType(QuillEditor)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await editorMenuGesture.up();
    await tester.pumpAndSettle();
    expect(find.text('コピー'), findsOneWidget);
    expect(find.text('切り取り'), findsOneWidget);
    expect(find.text('貼り付け'), findsOneWidget);
    await tester.tap(find.text('貼り付け'));
    await tester.pumpAndSettle();
    expect(doc.activeTab.text, contains('右クリックから貼り付け'));
    controller.addTab(doc, '測定器');
    await tester.pump();
    final secondEditor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    secondEditor.focusNode.requestFocus();
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '別のタブ\n',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    await tester.idle();
    await tester.pump();
    expect(doc.activeTab.text, contains('別のタブ'));
    controller.selectTab(doc, doc.tabs.first.id);
    await tester.pump();
    expect(doc.activeTab.text, contains('日本語の文章'));
    expect(
      tester.widget<InputChip>(find.byType(InputChip).first).onDeleted,
      isNull,
    );
    final textTitle =
        tester.widget<InputChip>(find.byType(InputChip).first).label as Text;
    expect(textTitle.style?.fontSize, 16);
    expect(textTitle.style?.fontWeight, FontWeight.w600);
    final tabMenuGesture = await tester.startGesture(
      tester.getCenter(find.byType(InputChip).first),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tabMenuGesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('削除'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    expect(doc.tabs.length, 2);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(controller.documents.length, 1);
    expect(controller.current!.tabs.first.text, contains('日本語の文章'));
    await tester.tap(
      find.byType(ChoiceChip).first,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('名前を変更'), findsOneWidget);
    expect(find.text('複製'), findsOneWidget);
    expect(find.text('削除'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    controller.create();
    await tester.pumpAndSettle();
    expect(controller.documents.map((item) => item.name), ['無題1', '無題2']);
    final titleText = tester.widget<Text>(
      find.descendant(
        of: find.byType(ChoiceChip).first,
        matching: find.byType(Text),
      ),
    );
    expect(titleText.style?.fontSize, 20);
    expect(titleText.style?.fontWeight, FontWeight.w700);
    final firstDocumentCenter = tester.getCenter(find.byType(ChoiceChip).first);
    final secondDocumentCenter = tester.getCenter(find.byType(ChoiceChip).last);
    final documentDrag = await tester.startGesture(
      secondDocumentCenter,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await documentDrag.moveTo(
      Offset(
        (firstDocumentCenter.dx + secondDocumentCenter.dx) / 2,
        firstDocumentCenter.dy,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await documentDrag.moveTo(firstDocumentCenter);
    await tester.pump(const Duration(milliseconds: 500));
    await documentDrag.up();
    await tester.pumpAndSettle();
    expect(controller.documents.map((item) => item.name), ['無題2', '無題1']);

    final reorderedDoc = controller.current!;
    controller.addTab(reorderedDoc, '二つ目');
    await tester.pumpAndSettle();
    final firstTabCenter = tester.getCenter(find.byType(InputChip).first);
    final secondTabCenter = tester.getCenter(find.byType(InputChip).last);
    final tabDrag = await tester.startGesture(
      secondTabCenter,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tabDrag.moveTo(
      Offset((firstTabCenter.dx + secondTabCenter.dx) / 2, firstTabCenter.dy),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tabDrag.moveTo(firstTabCenter);
    await tester.pump(const Duration(milliseconds: 500));
    await tabDrag.up();
    await tester.pumpAndSettle();
    expect(reorderedDoc.tabs.map((item) => item.name), ['二つ目', 'メモ']);
    await tester.pumpWidget(const SizedBox());
  });
}

