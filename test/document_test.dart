import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:tnote/models/document.dart';
import 'package:tnote/services/document_store.dart';
import 'package:tnote/services/document_controller.dart';
import 'package:tnote/services/recovery_store.dart';
import 'package:tnote/services/backup_service.dart';
import 'package:tnote/services/export_service.dart';
import 'package:tnote/services/file_lock_service.dart';

void main() {
  late Directory directory;
  late DocumentStore store;
  late DocumentController controller;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tnote-test-');
    store = DocumentStore();
    controller = DocumentController(
      store: store,
      recovery: RecoveryStore(Directory(p.join(directory.path, 'recovery'))),
      startTimers: false,
    );
    await controller.initialize();
  });
  tearDown(() async {
    await controller.flushAll();
    controller.dispose();
    await directory.delete(recursive: true);
  });
  String target(String name) => p.join(directory.path, name);

  test('日本語/空白パスにSQLiteとして新規保存し、再読込する', () async {
    final doc = controller.create();
    controller.edit(doc, doc.activeTab, '日本語 😀\n2行目');
    expect(
      await controller.save(doc, destination: target('仕事 メモ.tnote')),
      isTrue,
    );
    expect(doc.dirty, isFalse);
    expect(doc.requiresSaveConfirmation, isFalse);
    final loaded = await store.open(doc.path!);
    expect(loaded.activeTab.text, '日本語 😀\n2行目');
    final db = sqlite3.open(doc.path!, mode: OpenMode.readOnly);
    expect(db.select('PRAGMA journal_mode').single.values.first, 'delete');
    expect(
      db.select('SELECT plain_text FROM tabs').single.values.first,
      loaded.activeTab.text,
    );
    db.close();
    expect(await File('${doc.path}-wal').exists(), isFalse);
  });

  test('従来形式を開き、複数タイトル形式へ安全に更新する', () async {
    final path = target('従来形式.tnote');
    final db = sqlite3.open(path);
    final now = DateTime.now().toUtc().toIso8601String();
    db.execute('PRAGMA application_id = 1414418260');
    db.execute('PRAGMA user_version = 1');
    db.execute(
      'CREATE TABLE document_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    db.execute(
      'CREATE TABLE tabs (id TEXT PRIMARY KEY, tab_name TEXT NOT NULL, '
      'tab_order INTEGER NOT NULL, content TEXT NOT NULL, plain_text TEXT NOT NULL, '
      'created_at TEXT NOT NULL, updated_at TEXT NOT NULL)',
    );
    db.execute('INSERT INTO document_meta VALUES (?, ?)', ['id', 'legacy-doc']);
    db.execute('INSERT INTO document_meta VALUES (?, ?)', [
      'active_tab_id',
      'legacy-tab',
    ]);
    db.execute('INSERT INTO document_meta VALUES (?, ?)', [
      'custom_name',
      '従来の仕事',
    ]);
    db.execute('INSERT INTO tabs VALUES (?, ?, ?, ?, ?, ?, ?)', [
      'legacy-tab',
      'メモ',
      0,
      jsonEncode({
        'format': 'delta-v1',
        'delta': [
          {'insert': '従来の本文\n'},
        ],
        'text': '従来の本文\n',
      }),
      '従来の本文\n',
      now,
      now,
    ]);
    db.close();

    final legacy = await store.openWorkspace(path);
    expect(legacy.documents.single.name, '従来の仕事');
    final added = NoteDocument.create(2)..customName = '追加タイトル';
    await store.saveWorkspace(
      [legacy.documents.single, added],
      added.id,
      path,
      create: false,
    );
    final migrated = await store.openWorkspace(path);
    expect(migrated.documents.map((doc) => doc.name), ['従来の仕事', '追加タイトル']);
    final migratedDb = sqlite3.open(path, mode: OpenMode.readOnly);
    expect(migratedDb.select('PRAGMA user_version').single.values.first, 2);
    migratedDb.close();
  });
  test('保存後に同じ本文通知が来ても未保存状態へ戻らない', () async {
    final doc = controller.create();
    controller.editRich(doc, doc.activeTab, [
      {'insert': '保存済み\n'},
    ], '保存済み\n');
    expect(
      await controller.save(doc, destination: target('保存済み.tnote')),
      isTrue,
    );
    expect(doc.dirty, isFalse);
    controller.editRich(
      doc,
      doc.activeTab,
      List<dynamic>.from(
        doc.activeTab.delta.map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      ),
      doc.activeTab.text,
    );
    expect(doc.dirty, isFalse);
  });

  test('保存済みのフォント指定を読み込み時に除去する', () {
    final tab = NoteTab(
      id: 'font-test',
      name: 'メモ',
      text: '本文\n',
      delta: [
        {
          'insert': '本文',
          'attributes': {'font': 'Meiryo', 'bold': true},
        },
        {'insert': '\n'},
      ],
      createdAt: DateTime.now().toUtc().toIso8601String(),
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    final attributes = (tab.delta.first as Map)['attributes'] as Map;
    expect(attributes.containsKey('font'), isFalse);
    expect(attributes['bold'], isTrue);
  });
  test('上段の複数タイトルを一つのファイルとして保存し再読込する', () async {
    final first = controller.create();
    final second = controller.create();
    final third = controller.create();
    controller.renameDocument(first, '仕事');
    controller.renameDocument(second, '要領書');
    controller.renameDocument(third, 'NC旋盤');
    controller.edit(first, first.activeTab, '仕事の文章');
    controller.edit(second, second.activeTab, '要領書の文章');
    controller.edit(third, third.activeTab, 'NC旋盤の文章');
    final originalPath = target('仕事.tnote');
    await controller.save(first, destination: originalPath);
    expect(
      controller.documents.every((doc) => doc.path == originalPath),
      isTrue,
    );

    final reopened = await store.openWorkspace(originalPath);
    expect(reopened.documents.map((doc) => doc.name), ['仕事', '要領書', 'NC旋盤']);
    expect(reopened.documents.map((doc) => doc.activeTab.text), [
      '仕事の文章',
      '要領書の文章',
      'NC旋盤の文章',
    ]);

    controller.edit(first, first.activeTab, '更新した仕事の文章');
    expect(
      await controller.save(first, destination: target('仕事のコピー.tnote')),
      isTrue,
    );
    final original = await store.openWorkspace(originalPath);
    final copy = await store.openWorkspace(target('仕事のコピー.tnote'));
    expect(original.documents.first.activeTab.text, '仕事の文章');
    expect(copy.documents.first.activeTab.text, '更新した仕事の文章');
    expect(copy.documents.length, 3);
    await controller.closeWorkspace();
    await controller.open(originalPath);
    expect(controller.documents.map((doc) => doc.name), ['仕事', '要領書', 'NC旋盤']);
  });
  test('タブ追加・変更・削除と選択状態を保存する', () async {
    final doc = controller.create();
    controller.edit(doc, doc.activeTab, '最初');
    controller.addTab(doc, '測定器');
    controller.edit(doc, doc.activeTab, '二番目');
    controller.renameTab(doc, doc.activeTab, 'NC旋盤');
    await controller.save(doc, destination: target('タブ.tnote'));
    final loaded = await store.open(doc.path!);
    expect(loaded.tabs.map((t) => t.name), ['メモ', 'NC旋盤']);
    expect(loaded.activeTab.text, '二番目');
    controller.deleteTab(doc, doc.activeTab);
    await controller.save(doc);
    expect((await store.open(doc.path!)).tabs.single.text, '最初');
    controller.deleteTab(doc, doc.activeTab);
    expect(doc.tabs.length, 1);
  });
  test('保存先未指定の下書きを復元できる', () async {
    final doc = controller.create();
    controller.edit(doc, doc.activeTab, '突然終了の前の文章');
    await controller.flushAll();
    expect(doc.path, isNull);
    final recovered = await controller.recovery.load();
    expect(recovered.single.activeTab.text, '突然終了の前の文章');
    expect(recovered.single.dirty, isTrue);
    await controller.save(doc, destination: target('復元.tnote'));
    expect(await controller.recovery.load(), isEmpty);
  });
  test('外部変更を上書きせず復旧データを保持する', () async {
    final doc = controller.create();
    await controller.save(doc, destination: target('競合.tnote'));
    final external = await store.open(doc.path!);
    external.activeTab.text = '外部端末';
    await store.save(external, doc.path!, create: false);
    controller.edit(doc, doc.activeTab, 'この端末');
    expect(await controller.save(doc), isFalse);
    expect(doc.error, contains('別の端末'));
    expect(doc.dirty, isTrue);
    expect((await store.open(doc.path!)).activeTab.text, '外部端末');
    expect((await controller.recovery.load()).single.activeTab.text, 'この端末');
    expect(
      await controller.save(doc, destination: target('競合の別名.tnote')),
      isTrue,
    );
  });
  test('既存ファイルへの別名保存を拒否し内容を保持する', () async {
    final file = File(target('既存.tnote'));
    await file.writeAsString('別のデータ');
    final doc = controller.create();
    expect(await controller.save(doc, destination: file.path), isFalse);
    expect(await file.readAsString(), '別のデータ');
    expect(doc.path, isNull);
  });
  test('破損・未知形式・存在しないファイルを開かない', () async {
    final bad = File(target('壊れた.tnote'));
    await bad.writeAsString('not sqlite');
    await expectLater(store.open(bad.path), throwsA(anything));
    await expectLater(
      store.open(target('存在しない.tnote')),
      throwsA(isA<FileSystemException>()),
    );
    final db = sqlite3.open(target('未知.tnote'));
    db.execute('CREATE TABLE other (id INTEGER)');
    db.close();
    await expectLater(
      store.open(target('未知.tnote')),
      throwsA(isA<FormatException>()),
    );
  });
  test('100タブと長文を再読込できる', () async {
    final doc = controller.create();
    final longText = List.filled(10000, '日本語の長文\n').join();
    controller.edit(doc, doc.activeTab, longText);
    for (var i = 1; i < 100; i++) {
      controller.addTab(doc, 'タブ$i');
    }
    await controller.save(doc, destination: target('100タブ.tnote'));
    final loaded = await store.open(doc.path!);
    expect(loaded.tabs.length, 100);
    expect(loaded.tabs.first.text, longText);
  });
  test('同じファイルを同一セッション内で二重に開かない', () async {
    final doc = controller.create();
    await controller.save(doc, destination: target('重複.tnote'));
    await controller.open(doc.path!);
    expect(controller.documents.length, 1);
  });
  test('保存と次の編集が競合しても新しい変更を失わない', () async {
    final doc = controller.create();
    controller.edit(doc, doc.activeTab, '最初');
    final saving = controller.save(doc, destination: target('連続.tnote'));
    await Future<void>.delayed(Duration.zero);
    controller.edit(doc, doc.activeTab, '最新');
    await saving;
    await controller.save(doc);
    expect((await store.open(doc.path!)).activeTab.text, '最新');
    expect(doc.dirty, isFalse);
  });
  test('下書きを繰り返し更新し、破棄して閉じられる', () async {
    final doc = controller.create();
    await controller.save(doc);
    controller.edit(doc, doc.activeTab, '更新');
    await controller.save(doc);
    expect((await controller.recovery.load()).single.activeTab.text, '更新');
    await controller.close(doc, discard: true);
    expect(controller.documents, isEmpty);
    expect(await controller.recovery.load(), isEmpty);
  });
  test('800msの入力後自動保存と5秒の定期保存', () async {
    final timed = DocumentController(
      store: store,
      recovery: controller.recovery,
    );
    await timed.initialize();
    try {
      final doc = timed.create();
      await timed.save(doc, destination: target('自動保存.tnote'));
      timed.edit(doc, doc.activeTab, '入力後に保存');
      await Future<void>.delayed(const Duration(milliseconds: 2600));
      expect((await store.open(doc.path!)).activeTab.text, '入力後に保存');
      // Bypass the debounce to exercise the periodic safety net independently.
      doc.activeTab.text = '定期保存で救出';
      doc.changed();
      await Future<void>.delayed(const Duration(milliseconds: 4300));
      expect((await store.open(doc.path!)).activeTab.text, '定期保存で救出');
    } finally {
      await timed.flushAll();
      timed.dispose();
    }
  });
  test('保存先エラーでも下書きを保持し閉じることを拒否する', () async {
    final doc = controller.create();
    controller.edit(doc, doc.activeTab, '保存失敗しても消さない');
    expect(
      await controller.save(doc, destination: target('存在しないフォルダ/文書.tnote')),
      isFalse,
    );
    expect(doc.dirty, isTrue);
    await expectLater(controller.close(doc), throwsStateError);
    expect(
      (await controller.recovery.load()).single.activeTab.text,
      '保存失敗しても消さない',
    );
  });
  test('破損した復旧ファイルを削除せず警告する', () async {
    final file = File(
      p.join(controller.recovery.directory.path, 'broken.json'),
    );
    await file.writeAsString('{broken');
    expect(await controller.recovery.load(), isEmpty);
    expect(controller.recovery.warnings, isNotEmpty);
    expect(await file.exists(), isTrue);
  });

  test('リッチテキストDeltaをSQLiteへ保存して復元する', () async {
    final doc = controller.create();
    controller.editRich(doc, doc.activeTab, [
      {
        'insert': '太字',
        'attributes': {'bold': true},
      },
      {'insert': '\n'},
    ], '太字\n');
    await controller.save(doc, destination: target('リッチ.tnote'));
    final loaded = await store.open(doc.path!);
    expect(loaded.activeTab.text, '太字\n');
    expect((loaded.activeTab.delta.first as Map)['attributes'], {'bold': true});
  });

  test('タブ複製、並べ替え、全タブ検索', () {
    final doc = controller.create();
    controller.edit(doc, doc.activeTab, '改善案と測定器');
    controller.duplicateTab(doc, doc.activeTab);
    controller.duplicateTab(doc, doc.tabs.first);
    expect(doc.tabs.map((tab) => tab.name), ['メモ', 'メモ コピー2', 'メモ コピー']);
    controller.reorderTab(doc, 2, 0);
    expect(doc.tabs.first.name, 'メモ コピー');
    final hits = controller.search(doc, '測定器');
    expect(hits.length, 3);
    expect(hits.first.excerpt, contains('改善案'));
  });

  test('文書名、文書の複製、文書順を保存・操作できる', () async {
    final source = controller.create();
    controller.edit(source, source.activeTab, '複製する本文');
    controller.renameDocument(source, '設備メモ');
    expect(source.name, '設備メモ');
    expect(
      await controller.save(source, destination: target('元文書.tnote')),
      isTrue,
    );
    final loaded = await store.open(source.path!);
    expect(loaded.name, '設備メモ');

    final copy = controller.duplicateDocument(source);
    expect(copy.name, '設備メモ コピー');
    expect(copy.path, source.path);
    expect(copy.activeTab.text, '複製する本文');
    expect(copy.id, isNot(source.id));
    expect(copy.activeTab.id, isNot(source.activeTab.id));
    controller.reorderDocument(1, 0);
    expect(controller.documents, [copy, source]);
    await controller.save(copy);
    final reopened = await store.openWorkspace(source.path!);
    expect(reopened.documents.map((doc) => doc.name), ['設備メモ コピー', '設備メモ']);
  });

  test('バックアップを指定世代数に整理して復元用に列挙する', () async {
    final doc = controller.create();
    await controller.save(doc, destination: target('世代.tnote'));
    final backups = BackupService(Directory(target('backups')));
    for (var i = 0; i < 4; i++) {
      await backups.create(doc.path!, 3);
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    final entries = await backups.list(doc.path!);
    expect(entries.length, 3);
    expect(await store.open(entries.first.path), isNotNull);
  });

  test('現在タブと全タブをtxt/mdへ書き出す', () async {
    final doc = controller.create();
    controller.edit(doc, doc.activeTab, '本文A');
    controller.addTab(doc, '二番目');
    controller.edit(doc, doc.activeTab, '本文B');
    final exporter = ExportService();
    await exporter.exportTab(doc.activeTab, target('tab.md'), markdown: true);
    await exporter.exportAll(doc, target('all.txt'), markdown: false);
    expect(await File(target('tab.md')).readAsString(), contains('# 二番目'));
    expect(await File(target('all.txt')).readAsString(), contains('本文A'));
    expect(await File(target('all.txt')).readAsString(), contains('本文B'));
  });

  test('別プロセス相当の同一ファイルロックを拒否する', () async {
    final lockDirectory = Directory(target('locks'));
    final first = FileLockService(lockDirectory);
    final second = FileLockService(lockDirectory);
    final path = target('ロック.tnote');
    await first.acquire(path);
    await expectLater(second.acquire(path), throwsA(isA<FileAlreadyOpen>()));
    await first.releaseAll();
    await second.acquire(path);
    await second.releaseAll();
  });

  test('後から同じファイルを開いた側は読み取り専用で上書きできない', () async {
    final path = target('OneDrive共有.tnote');
    final firstLocks = FileLockService(Directory(target('端末Aロック')));
    final secondLocks = FileLockService(Directory(target('端末Bロック')));
    final firstController = DocumentController(
      store: DocumentStore(),
      recovery: RecoveryStore(Directory(target('端末A復旧'))),
      locks: firstLocks,
      startTimers: false,
    );
    final secondController = DocumentController(
      store: DocumentStore(),
      recovery: RecoveryStore(Directory(target('端末B復旧'))),
      locks: secondLocks,
      startTimers: false,
    );
    addTearDown(() async {
      await firstController.shutdown();
      await secondController.shutdown();
      firstController.dispose();
      secondController.dispose();
    });

    final original = firstController.create();
    firstController.edit(original, original.activeTab, '端末Aの内容');
    expect(await firstController.save(original, destination: path), isTrue);
    await expectLater(
      secondController.open(path),
      throwsA(isA<FileAlreadyOpen>()),
    );
    await secondController.open(path, readOnly: true);
    final readOnly = secondController.current!;
    expect(readOnly.readOnly, isTrue);
    secondController.edit(readOnly, readOnly.activeTab, '端末Bからの変更');
    expect(readOnly.activeTab.text, '端末Aの内容');
    expect(await secondController.save(readOnly), isFalse);
    expect((await DocumentStore().open(path)).activeTab.text, '端末Aの内容');
  });

  test('外部更新を定期検査で検知する', () async {
    final doc = controller.create();
    await controller.save(doc, destination: target('監視.tnote'));
    final external = await store.open(doc.path!);
    external.activeTab.text = '外部更新';
    external.activeTab.delta = [
      {'insert': '外部更新\n'},
    ];
    await store.save(external, doc.path!, create: false);
    await controller.checkExternalChanges();
    expect(doc.externallyModified, isTrue);
  });

  test('変更がない終了前flushは短時間で完了する', () async {
    final doc = controller.create();
    await controller.save(doc, destination: target('終了.tnote'));
    final watch = Stopwatch()..start();
    await controller.flushAll();
    watch.stop();
    expect(watch.elapsedMilliseconds, lessThan(500));
  });
}
