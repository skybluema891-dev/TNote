import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:loro_crdt/loro_crdt.dart' as loro;
import 'package:path/path.dart' as p;

import '../models/document.dart';
import '../services/app_storage.dart';
import '../services/collaboration_link.dart';
import '../services/collaboration_session.dart';
import '../services/directory_access_service.dart';
import '../services/document_store.dart';
import '../services/file_service.dart';
import '../widgets/note_editor.dart';

class CollaborationScreen extends StatefulWidget {
  const CollaborationScreen({
    super.key,
    required this.support,
    required this.fontSize,
    this.legacyPath,
    this.openLink,
    this.onOpened,
  });
  final Directory support;
  final double fontSize;
  final String? legacyPath;
  final Map<String, dynamic>? openLink;
  final ValueChanged<String>? onOpened;
  @override
  State<CollaborationScreen> createState() => CollaborationScreenState();
}

class CollaborationScreenState extends State<CollaborationScreen> {
  var _editor = GlobalKey<NoteEditorState>();
  final _vault = const FlutterSecureStorage();
  CollaborationSession? _session;
  List<Map<String, dynamic>> _rooms = [];
  String? _title, _tab;
  NoteTab? _model;
  loro.LoroSubscription? _textEvents;
  bool _busy = false;
  String? _error;
  bool _storageBlocked = false;

  bool get safeToClose =>
      !_busy &&
      _session?.localFailure != true &&
      _editor.currentState?.inputInProgress != true;
  Directory get _cache =>
      Directory(p.join(widget.support.path, 'collaboration-v1'));

  @override
  void initState() {
    super.initState();
    _loadRooms();
  }

  Future<void> _loadRooms() async {
    final raw = await appPreferences().getString('collaboration.rooms.v1');
    if (raw != null && mounted) {
      setState(
        () => _rooms = (jsonDecode(raw) as List).cast<Map<String, dynamic>>(),
      );
    }
    final link = widget.openLink;
    if (link != null && mounted) await _run(() => _open(saved: link));
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } catch (e) {
      if (mounted) setState(() => _error = '処理を完了できませんでした。$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _ask(
    String label, {
    String value = '',
    bool secret = false,
  }) async {
    var input = value;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: TextFormField(
          initialValue: value,
          autofocus: true,
          obscureText: secret,
          autocorrect: false,
          enableSuggestions: !secret,
          onChanged: (s) => input = s,
          onFieldSubmitted: (s) => Navigator.pop(ctx, s.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, input.trim()),
            child: const Text('決定'),
          ),
        ],
      ),
    );
  }

  Future<void> _showKey(String key) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('他の端末で参加するためのキー'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'このキーを安全な場所に控えてください。ご自身の別端末で「参加」を選び、同じ共有フォルダーとこのキーを指定します。',
          ),
          const SizedBox(height: 12),
          SelectableText(key),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('閉じる'),
        ),
      ],
    ),
  );

  Future<void> _open({bool create = false, Map<String, dynamic>? saved}) async {
    final path =
        saved?['path'] as String? ??
        await getDirectoryPath(confirmButtonText: '共有フォルダーを選択');
    if (path == null || !mounted) return;
    if (saved == null &&
        !await DirectoryAccessService().ensureForFile(
          p.join(path, 'TNote-room'),
        )) {
      return;
    }
    if (!mounted) return;
    String? code;
    String? sourceFingerprint;
    if (create && widget.legacyPath != null) {
      final source = widget.legacyPath!;
      sourceFingerprint = await DocumentStore().currentFingerprint(source);
      final existing = CollaborationLink.fileFor(
        Directory(path),
        p.basenameWithoutExtension(source),
        sourceFingerprint,
      );
      if (await existing.exists()) {
        final id = await CollaborationLink.read(existing.path);
        if (id == null) throw StateError('同名ファイルが既にあります。');
        await _open(saved: {'id': id, 'path': path});
        return;
      }
    }
    if (create) {
      if (sourceFingerprint != null) {
        code = await _vault.read(key: 'tnote-import-$sourceFingerprint');
      }
      code ??= CollaborationSession.newKey();
      if (sourceFingerprint != null) {
        await _vault.write(key: 'tnote-import-$sourceFingerprint', value: code);
      }
    } else {
      if (saved != null) {
        try {
          code = await _vault.read(key: 'tnote-room-${saved['id']}');
        } catch (_) {}
      }
      if (!mounted) return;
      code ??= await _ask('参加キーを入力', secret: true);
    }
    if (code == null || !mounted) return;
    final session = await CollaborationSession.open(
      support: _cache,
      exchange: Directory(path),
      code: code,
    );
    try {
      if (saved != null && saved['id'] != session.room) {
        throw const FormatException('このメモの参加キーと一致しません。');
      }
      String name;
      if (create) {
        final source = widget.legacyPath;
        final StoredWorkspace seed;
        if (source != null) {
          final backup = Directory(
            p.join(_cache.path, 'migration', session.room),
          );
          await backup.create(recursive: true);
          final snapshotPath = p.join(backup.path, 'original.tnote');
          if (!await File(snapshotPath).exists()) {
            await DocumentStore().backupWorkspace(source, snapshotPath);
          }
          if (await DocumentStore().currentFingerprint(source) !=
              sourceFingerprint) {
            throw StateError('取り込み中に元のファイルが更新されました。再度開いてください。');
          }
          seed = await DocumentStore().openWorkspace(snapshotPath);
          name = p.basenameWithoutExtension(source);
        } else {
          if (!mounted) return;
          final answer = await _ask('共同編集メモの名前', value: '共同メモ');
          if (answer == null || answer.isEmpty) return;
          name = answer;
          final first = NoteDocument.create(1)..customName = name;
          seed = StoredWorkspace(
            documents: [first],
            activeDocumentId: first.id,
          );
        }
        await session.createExchange();
        if (session.replica.titles.isEmpty) {
          session.edit((r) {
            r.seed(seed);
            r.document.getMap('workspace')['name'] = name;
          });
        }
        await session.sync();
        await CollaborationLink.create(
          Directory(path),
          name,
          session.room,
          sourceFingerprint: sourceFingerprint,
        );
        if (!mounted) return;
        await _showKey(code);
      } else {
        session.paused =
            await appPreferences().getBool(
              'collaboration.paused.${session.room}',
            ) ??
            false;
        if (session.paused) session.status = '通信を一時停止中・端末内に保存済み';
        await session.sync();
        if (session.replica.titles.isEmpty) {
          throw StateError('共同メモを取得できません。共有先、参加キー、作成元の送信状態を確認してください。');
        }
        name =
            session.replica.document.getMap('workspace')['name'] as String? ??
            '共同メモ';
      }
      if (!mounted) return;
      String? vaultWarning;
      try {
        await _vault.write(key: 'tnote-room-${session.room}', value: code);
      } catch (_) {
        vaultWarning = 'この端末では参加キーを保存できません。次回は再入力してください。';
      }
      final rooms = [
        {'id': session.room, 'path': path, 'name': name},
        ..._rooms.where((r) => r['id'] != session.room),
      ];
      await appPreferences().setString(
        'collaboration.rooms.v1',
        jsonEncode(rooms),
      );
      if (!mounted) return;
      setState(() {
        _session = session;
        _rooms = rooms;
        _error = vaultWarning;
      });
      session.deferReceive = () =>
          _busy || _editor.currentState?.inputInProgress == true;
      session.onReceive = _refresh;
      session.addListener(_storageStatus);
      widget.onOpened?.call(name);
      _refresh();
      session.start();
    } finally {
      if (!identical(_session, session)) await session.shutdown();
    }
  }

  void _refresh() {
    if (!mounted) return;
    final r = _session!.replica;
    final titles = r.ids(r.titles);
    if (!titles.contains(_title)) _title = titles.firstOrNull;
    final tabs = _title == null ? <String>[] : r.ids(r.tabs(_title!));
    if (!tabs.contains(_tab)) _tab = tabs.firstOrNull;
    if (_tab != null) {
      if (_model?.id != _tab) {
        _textEvents?.unsubscribe();
        _editor = GlobalKey<NoteEditorState>();
        _model = NoteTab(
          id: _tab!,
          name: r.meta(_tab!)['name'] as String,
          delta: r.content(_tab!),
          createdAt: '',
          updatedAt: '',
        );
        final tab = _tab!;
        _textEvents = r.body(tab).subscribe((batch) {
          if (batch.by != loro.EventTrigger.import) return;
          for (final event in batch.events) {
            final diff = event.diff;
            if (diff is loro.TextDiff) {
              final editor = _editor.currentState;
              if (editor != null) {
                editor.receiveOperations([
                  for (final op in diff.delta) op.toJson(),
                ]);
              } else {
                _model!.delta = r.content(tab);
              }
            }
          }
        });
      }
    } else {
      _textEvents?.unsubscribe();
      _textEvents = null;
      _model = null;
    }
    setState(() {});
  }

  void _storageStatus() {
    final failed = _session?.localFailure == true;
    if (mounted && failed != _storageBlocked) {
      setState(() => _storageBlocked = failed);
    }
  }

  Future<void> _structure(bool title, String action, [String? target]) async {
    final session = _session!;
    final r = session.replica;
    final list = title ? r.titles : r.tabs(_title!);
    final id = target ?? (title ? _title : _tab);
    if (action == 'add' || action == 'rename') {
      final name = await _ask(
        action == 'add' ? '名前を入力' : '名前を変更',
        value: action == 'rename' ? r.meta(id!)['name'] as String : '',
      );
      if (name == null || name.isEmpty) return;
      session.edit((r) {
        if (action == 'rename') {
          r.meta(id!)['name'] = name;
          return;
        }
        final next = newId();
        r.add(list, next, name);
        if (title) {
          _title = next;
          _tab = newId();
          r.add(r.tabs(next), _tab!, 'メモ');
        } else {
          _tab = next;
        }
        r.applyText(_tab!, [
          {'insert': '\n'},
        ]);
      });
    } else if (action == 'delete' && id != null) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('削除しますか？'),
          content: const Text('他の端末にも反映します。「削除した項目」から復元できます。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('いいえ'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('はい'),
            ),
          ],
        ),
      );
      if (yes == true) session.edit((r) => r.meta(id)['deleted'] = true);
    } else if (action == 'restore') {
      final gone = r.ids(list, deleted: true);
      if (!mounted) return;
      final restore = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('削除した項目'),
          children: [
            if (gone.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('削除した項目はありません。'),
              ),
            for (final item in gone)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, item),
                child: Text(r.meta(item)['name'] as String),
              ),
          ],
        ),
      );
      if (restore != null) {
        session.edit((r) => r.meta(restore)['deleted'] = false);
      }
    }
    _refresh();
  }

  Widget _strip(bool title) {
    final r = _session!.replica;
    final list = title ? r.titles : r.tabs(_title!);
    final ids = r.ids(list);
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          Expanded(
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              itemCount: ids.length,
              onReorderItem: (old, next) {
                if (old == next) return;
                _session!.edit((r) => r.move(list, ids[old], ids[next]));
                _refresh();
              },
              itemBuilder: (ctx, index) {
                final id = ids[index];
                return ReorderableDragStartListener(
                  key: ValueKey(id),
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 3,
                      vertical: 5,
                    ),
                    child: ChoiceChip(
                      selected: (title ? _title : _tab) == id,
                      label: Text(
                        r.meta(id)['name'] as String,
                        style: title
                            ? const TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.bold,
                              )
                            : null,
                      ),
                      onSelected: (_) {
                        if (title) {
                          _title = id;
                        } else {
                          _tab = id;
                        }
                        _refresh();
                      },
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            tooltip: title ? 'タイトルを追加' : 'タブを追加',
            icon: const Icon(Icons.add),
            onPressed: () => _run(() => _structure(title, 'add')),
          ),
          PopupMenuButton<String>(
            tooltip: title ? 'タイトルの操作' : 'タブの操作',
            onSelected: (s) => _run(() => _structure(title, s)),
            itemBuilder: (_) => [
              if (ids.isNotEmpty)
                const PopupMenuItem(value: 'rename', child: Text('名前を変更')),
              if (ids.isNotEmpty)
                const PopupMenuItem(value: 'delete', child: Text('削除')),
              const PopupMenuItem(value: 'restore', child: Text('削除した項目')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _export({int? sequence}) async {
    final room = sequence == null
        ? _session!.replica.workspace()
        : _session!.restoreAt(sequence);
    final path = await FileService().pickSave('共同メモの控え', null);
    if (path != null) {
      await DocumentStore().saveWorkspace(
        room.documents,
        room.activeDocumentId,
        path,
        create: true,
      );
    }
  }

  Future<void> _history() async {
    final seq = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('復元する時点を選択'),
        children: [
          for (final step in _session!.history)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, step.sequence),
              child: Text(
                '${step.time.toString().split('.').first}　変更 ${step.sequence}',
              ),
            ),
        ],
      ),
    );
    if (seq != null) await _export(sequence: seq);
  }

  Future<void> _pause() async {
    final s = _session!;
    await appPreferences().setBool('collaboration.paused.${s.room}', !s.paused);
    if (!mounted) return;
    setState(() {
      s.paused = !s.paused;
      s.status = s.paused ? '通信を一時停止中・端末内に保存済み' : '端末内に保存済み・同期待ち';
    });
    await s.sync();
  }

  @override
  void dispose() {
    _textEvents?.unsubscribe();
    final s = _session;
    if (s != null) {
      s.removeListener(_storageStatus);
      s.onReceive = null;
      unawaited(s.shutdown());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    return PopScope(
      canPop: safeToClose,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            s == null
                ? '共同編集'
                : s.replica.document.getMap('workspace')['name'] as String? ??
                      '共同メモ',
          ),
          actions: [
            if (s != null)
              IconButton(
                tooltip: s.paused ? '同期を再開' : '同期を一時停止',
                icon: Icon(s.paused ? Icons.sync : Icons.sync_disabled),
                onPressed: () => _run(_pause),
              ),
            if (s != null)
              IconButton(
                tooltip: '変更履歴から別ファイルへ復元',
                icon: const Icon(Icons.history),
                onPressed: () => _run(_history),
              ),
            if (s != null)
              IconButton(
                tooltip: '現在の内容を.tnoteに書き出す',
                onPressed: () => _run(_export),
                icon: const Icon(Icons.save_alt),
              ),
          ],
        ),
        body: Column(
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: SelectableText(_error!),
              ),
            if (s == null)
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    if (widget.legacyPath != null)
                      Text(
                        '「${p.basename(widget.legacyPath!)}」の全タイトルとタブを共同編集用に取り込みます。',
                      ),
                    FilledButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _run(() => _open(create: true)),
                      icon: const Icon(Icons.group_add),
                      label: Text(
                        widget.legacyPath == null
                            ? '共同メモを作成'
                            : 'このファイルから共同メモを作成',
                      ),
                    ),
                    OutlinedButton(
                      onPressed: _busy ? null : () => _run(() => _open()),
                      child: const Text('他の端末で作成したメモに参加'),
                    ),
                    for (final entry in _rooms)
                      ListTile(
                        leading: const Icon(Icons.groups),
                        title: Text(entry['name'] as String),
                        onTap: _busy
                            ? null
                            : () => _run(() => _open(saved: entry)),
                      ),
                  ],
                ),
              ),
            if (s != null) ...[
              _strip(true),
              Expanded(
                child: _model == null
                    ? const Center(child: Text('タイトルまたはタブを追加してください。'))
                    : NoteEditor(
                        key: _editor,
                        tab: _model!,
                        fontSize: widget.fontSize,
                        readOnly: s.localFailure,
                        onOperation: (ops) {
                          final id = _model!.id;
                          s.edit((r) => r.applyText(id, ops));
                        },
                        onChanged: (_, _) {},
                      ),
              ),
              if (_title != null) _strip(false),
              ListenableBuilder(
                listenable: s,
                builder: (_, _) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.sync),
                  title: Text(s.status),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
