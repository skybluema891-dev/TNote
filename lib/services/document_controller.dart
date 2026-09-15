import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/document.dart';
import 'document_store.dart';
import 'user_error.dart';
import 'recovery_store.dart';
import 'backup_service.dart';
import 'file_lock_service.dart';
import 'recent_files_service.dart';
import '../models/app_settings.dart';

class SearchHit {
  const SearchHit(this.tab, this.position, this.excerpt);
  final NoteTab tab;
  final int position;
  final String excerpt;
}

class DocumentController extends ChangeNotifier {
  DocumentController({
    required this.store,
    required this.recovery,
    this.backups,
    this.locks,
    this.recents,
    AppSettings? settings,
    this.startTimers = true,
  }) : settings = settings ?? AppSettings();
  final DocumentStore store;
  final RecoveryStore recovery;
  final BackupService? backups;
  final FileLockService? locks;
  final RecentFilesService? recents;
  final AppSettings settings;
  final bool startTimers;
  final List<NoteDocument> documents = [];
  List<NoteDocument> recoverable = [];
  NoteDocument? current;
  String? startupError;
  String? startupPath;
  Future<void> Function(String path)? openRequest;
  Timer? _debounce;
  Timer? _periodic;
  Timer? _conflictTimer;
  Future<void> _queue = Future.value();
  int _counter = 0;
  bool _disposed = false;
  bool _shutdown = false;
  String? get workspacePath => documents.isEmpty ? null : documents.first.path;
  String? get workspaceFingerprint =>
      documents.isEmpty ? null : documents.first.fingerprint;
  bool get workspaceReadOnly =>
      documents.isNotEmpty && documents.every((doc) => doc.readOnly);
  bool get workspaceDirty => documents.any((doc) => doc.dirty);
  bool get workspaceRequiresSaveConfirmation =>
      documents.isNotEmpty &&
      (workspacePath == null ||
          workspaceDirty ||
          documents.any((doc) => doc.error != null));
  Future<void> initialize() async {
    recoverable = await recovery.load();
    if (startTimers) {
      _periodic = Timer.periodic(const Duration(seconds: 5), (_) => flushAll());
      _conflictTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => checkExternalChanges(),
      );
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  NoteDocument create() {
    final doc = NoteDocument.create(++_counter);
    if (documents.isNotEmpty) {
      doc.path = workspacePath;
      doc.fingerprint = workspaceFingerprint;
      doc.readOnly = workspaceReadOnly;
    }
    documents.add(doc);
    current = doc;
    _schedule();
    notifyListeners();
    return doc;
  }

  Future<void> restore() async {
    documents.addAll(recoverable);
    _counter += recoverable.length;
    current = documents.isEmpty ? null : documents.last;
    recoverable = [];
    notifyListeners();
  }

  Future<void> discardRecovery() async {
    for (final doc in recoverable) {
      await recovery.remove(doc);
    }
    recoverable = [];
    notifyListeners();
  }

  Future<void> open(String path, {bool readOnly = false}) async {
    final canonical = await File(path).resolveSymbolicLinks();
    final currentPath = workspacePath;
    final sameFile =
        currentPath != null &&
        await File(currentPath).exists() &&
        await FileSystemEntity.identical(currentPath, canonical);
    if (_samePath(currentPath, canonical) || sameFile) {
      current ??= documents.firstOrNull;
      notifyListeners();
      return;
    }
    if (documents.isNotEmpty) {
      throw StateError('現在のファイルを閉じてから、別のファイルを開いてください。');
    }
    if (!readOnly) await locks?.acquire(canonical);
    var opened = false;
    try {
      final workspace = await store.openWorkspace(canonical);
      for (final doc in workspace.documents) {
        doc.readOnly = readOnly;
      }
      documents.addAll(workspace.documents);
      current = documents.firstWhere(
        (doc) => doc.id == workspace.activeDocumentId,
        orElse: () => documents.first,
      );
      _counter += documents.length;
      opened = true;
      await recents?.touch(canonical, limit: settings.recentLimit);
      notifyListeners();
    } finally {
      if (!opened && !readOnly) await locks?.release(canonical);
    }
  }

  bool _samePath(String? a, String? b) =>
      a != null &&
      b != null &&
      (Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b);
  void selectDocument(NoteDocument doc) {
    unawaited(flushAll());
    current = doc;
    notifyListeners();
  }

  void renameDocument(NoteDocument doc, String name) {
    if (doc.readOnly) return;
    doc.customName = name.trim();
    doc.changed();
    _schedule();
    notifyListeners();
  }

  NoteDocument duplicateDocument(NoteDocument source) {
    final existing = documents.map((doc) => doc.name).toSet();
    var suffix = 1;
    var name = '${source.name} コピー';
    while (existing.contains(name)) {
      suffix++;
      name = '${source.name} コピー$suffix';
    }
    final tabs = source.tabs
        .map(
          (tab) => NoteTab.create(tab.name)
            ..text = tab.text
            ..delta = List<dynamic>.from(
              tab.delta.map((item) => Map<String, dynamic>.from(item as Map)),
            ),
        )
        .toList();
    final activeIndex = source.tabs.indexWhere(
      (tab) => tab.id == source.activeTabId,
    );
    final copy = NoteDocument(
      id: newId(),
      temporaryName: name,
      customName: name,
      tabs: tabs,
      activeTabId: tabs[activeIndex < 0 ? 0 : activeIndex].id,
      path: workspacePath,
      fingerprint: workspaceFingerprint,
      readOnly: workspaceReadOnly,
    );
    documents.insert(documents.indexOf(source) + 1, copy);
    current = copy;
    _schedule();
    notifyListeners();
    return copy;
  }

  void reorderDocument(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    final doc = documents.removeAt(oldIndex);
    documents.insert(newIndex.clamp(0, documents.length), doc);
    if (documents.isNotEmpty && !workspaceReadOnly) {
      (current ?? documents.first).changed();
      _schedule();
    }
    notifyListeners();
  }

  void selectTab(NoteDocument doc, String id) {
    if (doc.activeTabId == id) return;
    doc.activeTabId = id;
    if (doc.readOnly) {
      notifyListeners();
      return;
    }
    doc.changed();
    unawaited(save(doc));
    notifyListeners();
  }

  void edit(NoteDocument doc, NoteTab tab, String text) {
    if (doc.readOnly) return;
    if (tab.text == text) return;
    tab.text = text;
    tab.updatedAt = DateTime.now().toUtc().toIso8601String();
    doc.changed();
    _schedule();
    notifyListeners();
  }

  void editRich(
    NoteDocument doc,
    NoteTab tab,
    List<dynamic> delta,
    String plainText,
  ) {
    if (doc.readOnly) return;
    if (tab.text == plainText && jsonEncode(tab.delta) == jsonEncode(delta)) {
      return;
    }
    tab
      ..delta = delta
      ..text = plainText
      ..updatedAt = DateTime.now().toUtc().toIso8601String();
    doc.changed();
    _schedule();
    notifyListeners();
  }

  void addTab(NoteDocument doc, String name) {
    if (doc.readOnly) return;
    final tab = NoteTab.create(name.trim());
    doc.tabs.add(tab);
    doc.activeTabId = tab.id;
    doc.changed();
    _schedule();
    notifyListeners();
  }

  void renameTab(NoteDocument doc, NoteTab tab, String name) {
    if (doc.readOnly) return;
    tab.name = name.trim();
    tab.updatedAt = DateTime.now().toUtc().toIso8601String();
    doc.changed();
    _schedule();
    notifyListeners();
  }

  void deleteTab(NoteDocument doc, NoteTab tab) {
    if (doc.readOnly) return;
    doc.tabs.remove(tab);
    if (doc.tabs.isEmpty) doc.tabs.add(NoteTab.create('メモ'));
    if (doc.activeTabId == tab.id) doc.activeTabId = doc.tabs.first.id;
    doc.changed();
    _schedule();
    notifyListeners();
  }

  void duplicateTab(NoteDocument doc, NoteTab source) {
    if (doc.readOnly) return;
    final existing = doc.tabs.map((tab) => tab.name).toSet();
    var suffix = 1;
    var name = '${source.name} コピー';
    while (existing.contains(name)) {
      suffix++;
      name = '${source.name} コピー$suffix';
    }
    final copy = NoteTab.create(name)
      ..text = source.text
      ..delta = List<dynamic>.from(
        source.delta.map((item) => Map<String, dynamic>.from(item as Map)),
      );
    final index = doc.tabs.indexOf(source) + 1;
    doc.tabs.insert(index, copy);
    doc.activeTabId = copy.id;
    doc.changed();
    _schedule();
    notifyListeners();
  }

  void reorderTab(NoteDocument doc, int oldIndex, int newIndex) {
    if (doc.readOnly) return;
    final tab = doc.tabs.removeAt(oldIndex);
    doc.tabs.insert(newIndex, tab);
    doc.changed();
    _schedule();
    notifyListeners();
  }

  List<SearchHit> search(
    NoteDocument doc,
    String query, {
    bool allTabs = true,
  }) {
    if (query.isEmpty) return [];
    final tabs = allTabs ? doc.tabs : [doc.activeTab];
    final needle = query.toLowerCase();
    return [
      for (final tab in tabs)
        for (
          var start = 0;
          (start = tab.text.toLowerCase().indexOf(needle, start)) >= 0;
          start += needle.length
        )
          SearchHit(
            tab,
            start,
            tab.text
                .substring(
                  (start - 25).clamp(0, tab.text.length),
                  (start + query.length + 45).clamp(0, tab.text.length),
                )
                .replaceAll('\n', ' '),
          ),
    ];
  }

  void _schedule() {
    if (!startTimers) return;
    _debounce?.cancel();
    if (!settings.autosave) return;
    _debounce = Timer(Duration(seconds: settings.autosaveSeconds), flushAll);
  }

  Future<void> _serialize(Future<void> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.catchError((Object _) {});
    return next;
  }

  Future<bool> save(NoteDocument doc, {String? destination}) async {
    if (workspaceReadOnly) {
      doc.error = 'このファイルは別の端末で開かれているため、読み取り専用です。上書き保存できません。';
      notifyListeners();
      return false;
    }
    var success = false;
    await _serialize(() async {
      if (!documents.contains(doc)) {
        success = true;
        return;
      }
      if (destination == null && !workspaceDirty) {
        success = true;
        return;
      }
      for (final item in documents) {
        item.saving = true;
      }
      notifyListeners();
      final snapshots = documents
          .map((item) => NoteDocument.fromJson(item.toJson()))
          .toList();
      String? newlyLockedPath;
      try {
        for (final snapshot in snapshots) {
          await recovery.write(snapshot);
        }
        final path = destination ?? workspacePath;
        if (path != null) {
          final create = !_samePath(workspacePath, path);
          final oldPath = workspacePath;
          if (create) {
            await locks?.acquire(path);
            newlyLockedPath = path;
          }
          if (!create) {
            await backups?.create(path, settings.backupGenerations);
          }
          final activeId = current?.id ?? snapshots.first.id;
          final stamp = await store.saveWorkspace(
            snapshots,
            activeId,
            path,
            create: create,
          );
          final canonicalPath = await File(path).resolveSymbolicLinks();
          for (var i = 0; i < documents.length; i++) {
            final item = documents[i];
            item.path = canonicalPath;
            item.fingerprint = stamp;
            item.externallyModified = false;
            item.savedRevision = snapshots[i].revision;
          }
          if (create && oldPath != null) await locks?.release(oldPath);
          newlyLockedPath = null;
          await recents?.touch(canonicalPath, limit: settings.recentLimit);
          for (final item in documents) {
            if (item.dirty) {
              await recovery.write(item);
            } else {
              await recovery.remove(item);
            }
          }
        }
        for (final item in documents) {
          item.error = null;
        }
        success = true;
      } catch (error) {
        if (newlyLockedPath != null) {
          await locks?.release(newlyLockedPath);
        }
        doc.error = userError(error);
        if (kDebugMode) debugPrint('TNote save failed: $error');
      } finally {
        for (final item in documents) {
          item.saving = false;
        }
        notifyListeners();
      }
    });
    return success;
  }

  Future<void> flushAll() async {
    await _queue;
    if (documents.isNotEmpty &&
        workspaceDirty &&
        !documents.any((doc) => doc.saving) &&
        !workspaceReadOnly) {
      await save(current ?? documents.first);
    }
    await _queue;
  }

  Future<void> adoptSavedCopy(NoteDocument doc, String path) async {
    await _serialize(() async {
      final canonical = await File(path).resolveSymbolicLinks();
      final oldPath = workspacePath;
      final changedPath = !_samePath(oldPath, canonical);
      if (changedPath) await locks?.acquire(canonical);
      try {
        final stamp = await store.currentFingerprint(canonical);
        for (final item in documents) {
          item.path = canonical;
          item.fingerprint = stamp;
          item.savedRevision = item.revision;
          item.error = null;
          item.externallyModified = false;
        }
        if (changedPath && oldPath != null) await locks?.release(oldPath);
        for (final item in documents) {
          await recovery.remove(item);
        }
        await recents?.touch(canonical, limit: settings.recentLimit);
      } catch (_) {
        if (changedPath) await locks?.release(canonical);
        rethrow;
      } finally {
        notifyListeners();
      }
    });
  }

  Future<void> shutdown() async {
    if (_shutdown) return;
    _shutdown = true;
    _debounce?.cancel();
    _periodic?.cancel();
    _conflictTimer?.cancel();
    await _queue;
    await locks?.releaseAll();
  }

  Future<void> checkExternalChanges() async {
    final path = workspacePath;
    if (path == null ||
        documents.any((doc) => doc.saving || doc.externallyModified)) {
      return;
    }
    try {
      final stamp = await store.currentFingerprint(path);
      if (stamp != workspaceFingerprint) {
        for (final doc in documents) {
          doc.externallyModified = true;
        }
        notifyListeners();
      }
    } catch (_) {
      for (final doc in documents) {
        doc.externallyModified = true;
      }
      notifyListeners();
    }
  }

  Future<void> reload(NoteDocument doc) async {
    final path = workspacePath;
    if (path == null) return;
    final loaded = await store.openWorkspace(path);
    final readOnly = workspaceReadOnly;
    documents
      ..clear()
      ..addAll(loaded.documents);
    for (final item in documents) {
      item.readOnly = readOnly;
    }
    current = documents.firstWhere(
      (item) => item.id == loaded.activeDocumentId,
      orElse: () => documents.first,
    );
    notifyListeners();
  }

  Future<void> restoreBackup(String backupPath) async {
    final loaded = await store.openWorkspace(backupPath);
    for (final source in loaded.documents) {
      final json = source.toJson()
        ..['id'] = newId()
        ..['path'] = null
        ..['fingerprint'] = null
        ..['savedRevision'] = -1;
      final restored = NoteDocument.fromJson(json);
      documents.add(restored);
      current = restored;
      await recovery.write(restored);
    }
    notifyListeners();
  }

  Future<void> deleteDocument(NoteDocument doc) async {
    if (doc.readOnly) return;
    await recovery.remove(doc);
    documents.remove(doc);
    if (documents.isEmpty) {
      if (doc.path != null) await locks?.release(doc.path!);
      current = null;
    } else {
      current = documents.contains(current) ? current : documents.last;
      (current ?? documents.first).changed();
      _schedule();
    }
    notifyListeners();
  }

  Future<void> closeWorkspace({bool discard = false}) async {
    await _serialize(() async {
      if (workspaceDirty && !discard) {
        throw StateError('保存前にファイルを閉じることはできません。');
      }
      final path = workspacePath;
      for (final doc in List<NoteDocument>.of(documents)) {
        if (!doc.readOnly) await recovery.remove(doc);
      }
      if (path != null && !workspaceReadOnly) await locks?.release(path);
      documents.clear();
      current = null;
      notifyListeners();
    });
  }

  Future<void> close(NoteDocument doc, {bool discard = false}) async {
    if (documents.length == 1) {
      await closeWorkspace(discard: discard);
      return;
    }
    if (doc.dirty && !discard) {
      throw StateError('保存前にタイトルを削除することはできません。');
    }
    await deleteDocument(doc);
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _periodic?.cancel();
    _conflictTimer?.cancel();
    if (!_shutdown) unawaited(locks?.releaseAll());
    super.dispose();
  }
}
