import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tnote/models/document.dart';
import 'package:tnote/services/directory_access_service.dart';
import 'package:tnote/services/export_service.dart';
import 'package:tnote/services/file_lock_service.dart';
import 'package:tnote/services/user_error.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('tnote-save-');
  });
  tearDown(() => root.delete(recursive: true));

  test('日本語と空白のフォルダ・ファイルにUTF-8で正確に書き出す', () async {
    final folder = await Directory(p.join(root.path, '保存先 日本語')).create();
    final doc = NoteDocument.create(1);
    doc.activeTab.text = '日本語の本文 😀\n二行目\n';
    final target = p.join(folder.path, '仕事 メモ.txt');
    await ExportService().exportTab(doc.activeTab, target, markdown: false);
    expect(await File(target).readAsBytes(), utf8.encode(doc.activeTab.text));
    doc.activeTab.text = '短い更新';
    await ExportService().exportTab(doc.activeTab, target, markdown: false);
    expect(await File(target).readAsString(), '短い更新');
  });

  test('存在しない保存先の書き出し失敗を日本語で案内できる', () async {
    try {
      await ExportService().exportTab(
        NoteDocument.create(1).activeTab,
        p.join(root.path, '存在しない', 'メモ.txt'),
        markdown: false,
      );
      fail('Must reject a missing destination');
    } on FileSystemException catch (error) {
      expect(userError(error), contains('アクセス権'));
    }
  });

  test('ロックファイルの保存先エラーを二重起動と誤判定しない', () async {
    final locks = FileLockService(Directory(p.join(root.path, 'locks')));
    addTearDown(locks.releaseAll);
    await expectLater(
      locks.acquire(p.join(root.path, '存在しない', '文書.tnote')),
      throwsA(isA<FileSystemException>()),
    );
    // Failed acquisition must release its local OS lock.
    await Directory(p.join(root.path, '存在しない')).create();
    await locks.acquire(p.join(root.path, '存在しない', '文書.tnote'));
  });

  test('OSのアクセス拒否を捕捉し、データを作成しない', () async {
    final folder = await Directory(p.join(root.path, '書込不可')).create();
    await Process.run('/bin/chmod', ['500', folder.path]);
    addTearDown(() => Process.run('/bin/chmod', ['700', folder.path]));
    final target = p.join(folder.path, 'メモ.txt');
    await expectLater(
      ExportService().exportTab(
        NoteDocument.create(1).activeTab,
        target,
        markdown: false,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await File(target).exists(), isFalse);
  }, skip: Platform.isWindows);

  test('フォルダ選択キャンセルとネイティブの日本語エラーを伝える', () async {
    const channel = MethodChannel('com.tnote.app/directory-access');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'lastDirectory') return '/保存先 日本語';
      if (call.method == 'ensureForFile') return false;
      return null;
    });
    final access = DirectoryAccessService();
    await access.restore();
    expect(await access.lastDirectory(), '/保存先 日本語');
    expect(await access.ensureForFile('/保存先 日本語/メモ.txt'), isFalse);
    expect(calls, ['restore', 'lastDirectory', 'ensureForFile']);
    const message = '保存先と同じフォルダを選択してください。';
    expect(
      userError(
        PlatformException(code: 'different_directory', message: message),
      ),
      message,
    );
  }, skip: !Platform.isMacOS);
}
