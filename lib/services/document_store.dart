import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../models/document.dart';

class DocumentConflict implements Exception {
  const DocumentConflict();
  @override
  String toString() => 'このファイルは別の端末またはアプリで変更されています。現在の内容をファイルに保存するか、開き直してください。';
}

class StoredWorkspace {
  const StoredWorkspace({
    required this.documents,
    required this.activeDocumentId,
  });
  final List<NoteDocument> documents;
  final String activeDocumentId;
}

/// SQLite connections are owned by background isolates and always closed there.
class DocumentStore {
  Future<StoredWorkspace> openWorkspace(String path) =>
      Isolate.run(() => readWorkspace(path));

  Future<NoteDocument> open(String path) async =>
      (await openWorkspace(path)).documents.first;

  Future<String> saveWorkspace(
    List<NoteDocument> documents,
    String activeDocumentId,
    String path, {
    required bool create,
  }) {
    final snapshots = documents.map((document) => document.toJson()).toList();
    return Isolate.run(
      () => writeWorkspace(snapshots, activeDocumentId, path, create),
    );
  }

  Future<String> save(
    NoteDocument document,
    String path, {
    required bool create,
  }) => saveWorkspace([document], document.id, path, create: create);

  Future<String> currentFingerprint(String path) =>
      Isolate.run(() => fingerprint(path));
}

String fingerprint(String path) =>
    sha256.convert(File(path).readAsBytesSync()).toString();

int validate(Database db) {
  final applicationId =
      db.select('PRAGMA application_id').single.values.first as int;
  final version = db.select('PRAGMA user_version').single.values.first as int;
  if (applicationId != 0x544e4f54 || (version != 1 && version != 2)) {
    throw const FormatException('未対応の.tnote形式です。元のファイルは変更していません。');
  }
  if (db.select('PRAGMA quick_check').single.values.first != 'ok') {
    throw const FormatException('ファイルが破損しています。');
  }
  return version;
}

Map<String, String> _meta(Database db) => {
  for (final row in db.select('SELECT key, value FROM document_meta'))
    row['key'] as String: row['value'] as String,
};

NoteTab _tabFromRow(Row row) {
  final content = jsonDecode(row['content'] as String) as Map<String, dynamic>;
  final format = content['format'];
  if (format != 'plain-v1' && format != 'delta-v1') {
    throw const FormatException('このバージョンでは編集できない本文形式です。');
  }
  return NoteTab(
    id: row['id'] as String,
    name: row['tab_name'] as String,
    text: content['text'] as String,
    delta: format == 'delta-v1'
        ? (content['delta'] as List).cast<dynamic>()
        : null,
    createdAt: row['created_at'] as String,
    updatedAt: row['updated_at'] as String,
  );
}

StoredWorkspace readWorkspace(String path) {
  if (!File(path).existsSync()) {
    throw FileSystemException('ファイルが存在しません', path);
  }
  final canonical = File(path).resolveSymbolicLinksSync();
  final before = fingerprint(canonical);
  final db = sqlite3.open(canonical, mode: OpenMode.readOnly);
  late StoredWorkspace result;
  try {
    final version = validate(db);
    final meta = _meta(db);
    if (version == 1) {
      final tabs = db
          .select('SELECT * FROM tabs ORDER BY tab_order')
          .map(_tabFromRow)
          .toList();
      if (tabs.isEmpty || meta['id'] == null) {
        throw const FormatException('文書情報が不正です。');
      }
      final active = meta['active_tab_id'];
      final document = NoteDocument(
        id: meta['id']!,
        temporaryName: '無題',
        customName: meta['custom_name'],
        tabs: tabs,
        activeTabId: tabs.any((tab) => tab.id == active)
            ? active!
            : tabs.first.id,
        path: canonical,
        fingerprint: before,
        savedRevision: 0,
      );
      result = StoredWorkspace(
        documents: [document],
        activeDocumentId: document.id,
      );
    } else {
      final rows = db.select(
        'SELECT id, document_name, document_order, active_tab_id '
        'FROM workspace_documents ORDER BY document_order',
      );
      final documents = <NoteDocument>[];
      for (final row in rows) {
        final id = row['id'] as String;
        final tabs = db
            .select(
              'SELECT * FROM tabs WHERE document_id = ? ORDER BY tab_order',
              [id],
            )
            .map(_tabFromRow)
            .toList();
        if (tabs.isEmpty) throw const FormatException('文書情報が不正です。');
        final activeTabId = row['active_tab_id'] as String;
        documents.add(
          NoteDocument(
            id: id,
            temporaryName: '無題',
            customName: row['document_name'] as String,
            tabs: tabs,
            activeTabId: tabs.any((tab) => tab.id == activeTabId)
                ? activeTabId
                : tabs.first.id,
            path: canonical,
            fingerprint: before,
            savedRevision: 0,
          ),
        );
      }
      if (documents.isEmpty) throw const FormatException('文書情報が不正です。');
      final activeDocumentId = meta['active_document_id'];
      result = StoredWorkspace(
        documents: documents,
        activeDocumentId: documents.any((doc) => doc.id == activeDocumentId)
            ? activeDocumentId!
            : documents.first.id,
      );
    }
  } finally {
    db.close();
  }
  if (fingerprint(canonical) != before) throw const DocumentConflict();
  return result;
}

String writeWorkspace(
  List<Map<String, dynamic>> snapshots,
  String activeDocumentId,
  String path,
  bool create,
) {
  if (snapshots.isEmpty) throw const FormatException('保存するタイトルがありません。');
  final documents = snapshots.map(NoteDocument.fromJson).toList();
  final target = File(path);
  if (create && target.existsSync()) {
    throw const FileSystemException('同名ファイルが存在します。別のファイル名を指定してください。');
  }
  final expectedFingerprint = documents.first.fingerprint;
  if (!create &&
      (!target.existsSync() || fingerprint(path) != expectedFingerprint)) {
    throw const DocumentConflict();
  }
  final workingPath = create ? '$path.${newId()}.tmp' : path;
  final db = sqlite3.open(
    workingPath,
    mode: create ? OpenMode.readWriteCreate : OpenMode.readWrite,
  );
  try {
    db.execute('PRAGMA busy_timeout = 3000');
    final existingVersion = create ? 0 : validate(db);
    db.execute('PRAGMA journal_mode = DELETE');
    db.execute('PRAGMA synchronous = FULL');
    db.execute('BEGIN IMMEDIATE');
    try {
      if (!create && fingerprint(path) != expectedFingerprint) {
        throw const DocumentConflict();
      }
      if (create) {
        db.execute('PRAGMA application_id = 1414418260');
        db.execute('PRAGMA user_version = 2');
        db.execute(
          'CREATE TABLE document_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        db.execute(
          'CREATE TABLE workspace_documents ('
          'id TEXT PRIMARY KEY, document_name TEXT NOT NULL, '
          'document_order INTEGER NOT NULL, active_tab_id TEXT NOT NULL)',
        );
        db.execute(
          'CREATE TABLE tabs ('
          'id TEXT PRIMARY KEY, document_id TEXT NOT NULL, '
          'tab_name TEXT NOT NULL, tab_order INTEGER NOT NULL, '
          'content TEXT NOT NULL, plain_text TEXT NOT NULL, '
          'created_at TEXT NOT NULL, updated_at TEXT NOT NULL)',
        );
      } else if (existingVersion == 1) {
        db.execute(
          'CREATE TABLE workspace_documents ('
          'id TEXT PRIMARY KEY, document_name TEXT NOT NULL, '
          'document_order INTEGER NOT NULL, active_tab_id TEXT NOT NULL)',
        );
        db.execute('ALTER TABLE tabs ADD COLUMN document_id TEXT');
        db.execute('PRAGMA user_version = 2');
      }
      db.execute('DELETE FROM document_meta');
      for (final entry in {
        'active_document_id': activeDocumentId,
        'schema_version': '2',
        'format_version': 'delta-v1',
        'content_format': 'delta-v1',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }.entries) {
        db.execute('INSERT INTO document_meta VALUES (?, ?)', [
          entry.key,
          entry.value,
        ]);
      }
      db.execute('DELETE FROM tabs');
      db.execute('DELETE FROM workspace_documents');
      for (
        var documentOrder = 0;
        documentOrder < documents.length;
        documentOrder++
      ) {
        final document = documents[documentOrder];
        db.execute('INSERT INTO workspace_documents VALUES (?, ?, ?, ?)', [
          document.id,
          document.name,
          documentOrder,
          document.activeTabId,
        ]);
        for (var tabOrder = 0; tabOrder < document.tabs.length; tabOrder++) {
          final tab = document.tabs[tabOrder];
          db.execute(
            'INSERT INTO tabs '
            '(id, document_id, tab_name, tab_order, content, plain_text, created_at, updated_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            [
              tab.id,
              document.id,
              tab.name,
              tabOrder,
              jsonEncode({
                'format': 'delta-v1',
                'delta': tab.delta,
                'text': tab.text,
              }),
              tab.text,
              tab.createdAt,
              tab.updatedAt,
            ],
          );
        }
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  } finally {
    db.close();
  }
  if (create) {
    if (target.existsSync()) {
      File(workingPath).deleteSync();
      throw const FileSystemException('保存先にファイルが作成されました。別名を選んでください。');
    }
    File(workingPath).renameSync(path);
  }
  return fingerprint(path);
}
