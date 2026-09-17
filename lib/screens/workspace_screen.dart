import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/document.dart';
import '../services/document_controller.dart';
import '../services/file_service.dart';
import '../services/export_service.dart';
import '../services/file_lock_service.dart';
import '../services/settings_service.dart';
import '../services/share_service.dart';
import '../services/update_service.dart';
import '../widgets/note_editor.dart';
import '../services/user_error.dart';
import '../services/platform_document_service.dart';

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({
    super.key,
    this.desktop = false,
    this.version = '1.4.0',
    this.buildNumber = '13',
  });
  final bool desktop;
  final String version;
  final String buildNumber;
  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen>
    with WindowListener, WidgetsBindingObserver {
  final _files = FileService();
  final _export = ExportService();
  late final ShareService _share;
  late final UpdateService _updates;
  late DocumentController _controller;
  final ScrollController _documentScrollController = ScrollController();
  bool _busy = false;
  String? _title;
  String get _fileTitle {
    final current = _controller.current;
    if (current?.isPlainText == true) return current!.name;
    final path = _controller.workspacePath;
    return path == null ? '未保存' : p.basenameWithoutExtension(path);
  }

  @override
  void initState() {
    super.initState();
    _controller = context.read<DocumentController>();
    _share = ShareService(_export);
    _updates = UpdateService();
    _controller.openRequest = _openPath;
    WidgetsBinding.instance.addObserver(this);
    if (widget.desktop) {
      windowManager.addListener(this);
      _controller.addListener(_updateTitle);
      _updateTitle();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _finishStartup());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.openRequest = null;
    if (widget.desktop) {
      windowManager.removeListener(this);
      _controller.removeListener(_updateTitle);
    }
    _updates.close();
    _documentScrollController.dispose();
    super.dispose();
  }

  void _scrollDocumentTitles(double distance) {
    if (!_documentScrollController.hasClients) return;
    final position = _documentScrollController.position;
    final target = (_documentScrollController.offset + distance).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    unawaited(
      _documentScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      ),
    );
  }

  void _updateTitle() {
    final doc = _controller.current;
    final title = doc == null
        ? 'TNote'
        : '$_fileTitle${_controller.workspaceDirty ? ' *' : ''} — TNote';
    if (_title != title) {
      _title = title;
      unawaited(windowManager.setTitle(title));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_controller.flushAll());
  }

  @override
  void onWindowClose() => _run(_exit);
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      debugPrint('TNote: $error');
      if (mounted) await _message(userError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _message(String message) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('TNote'),
      content: SelectableText(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('閉じる'),
        ),
      ],
    ),
  );
  Future<void> _offerRecovery() async {
    if (_controller.startupError != null) {
      await _message(_controller.startupError!);
      _controller.startupError = null;
    }
    if (!mounted) return;
    if (_controller.recoverable.isNotEmpty) {
      await _controller.discardRecovery();
    }
    if (mounted && _controller.recovery.warnings.isNotEmpty) {
      await _message(_controller.recovery.warnings.join('\n'));
    }
  }

  Future<void> _finishStartup() async {
    await _offerRecovery();
    if (!mounted) return;
    final path = _controller.startupPath;
    _controller.startupPath = null;
    try {
      if (path != null) await _openPath(path);
    } finally {
      if (mounted) await PlatformDocumentService.notifyReady();
    }
    if (mounted && widget.desktop) await _checkForUpdates();
  }

  Future<void> _checkForUpdates({bool manual = false}) async {
    final info = await _updates.check(
      currentVersion: widget.version,
      currentBuild: int.tryParse(widget.buildNumber) ?? 0,
      manual: manual,
    );
    if (!mounted) return;
    if (info == null) {
      if (manual) await _message('利用できる新しいバージョンはありません。');
      return;
    }
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('TNoteの新しいバージョン ${info.version} があります'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('現在：${widget.version}'),
                Text('最新：${info.version}'),
                if (info.releaseNotes.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('主な変更'),
                  const SizedBox(height: 6),
                  for (final note in info.releaseNotes) Text('・$note'),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'skip'),
            child: const Text('このバージョンをスキップ'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'later'),
            child: const Text('後で'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'update'),
            child: const Text('今すぐ更新'),
          ),
        ],
      ),
    );
    if (action == 'skip') await _updates.skip(info.version);
    if (action == 'update') await _applyUpdate(info);
  }

  Future<void> _applyUpdate(ReleaseInfo info) async {
    if (Platform.isMacOS) {
      try {
        await _updates.openMacDownload(info);
      } catch (error) {
        if (mounted) await _message(userError(error));
      }
      return;
    }
    if (!Platform.isWindows) return;
    if (_controller.documents.isNotEmpty && _controller.workspacePath == null) {
      await _message('更新の前に、現在の内容を「ファイルに保存」してください。');
      return;
    }
    await _controller.flushAll();
    if (_controller.workspaceDirty ||
        _controller.documents.any((doc) => doc.error != null)) {
      await _message('保存を完了できなかったため、更新を開始しませんでした。現在のTNoteはそのまま使用できます。');
      return;
    }
    final installer = await _updates.downloadWindowsInstaller(info);
    await Process.start(installer.path, const [
      '/CLOSEAPPLICATIONS',
      '/NORESTART',
    ], mode: ProcessStartMode.detached);
    await _controller.shutdown();
    await windowManager.setPreventClose(false);
    exit(0);
  }

  Future<void> _showAbout() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('TNoteについて'),
      content: SelectableText(
        'TNote\nバージョン ${widget.version}\nビルド ${widget.buildNumber}\n\n'
        '複数タイトルを1つの.tnoteへ保存し、txt・md・logも直接編集できます。',
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('閉じる'),
        ),
      ],
    ),
  );

  Future<void> _openPath(String path) async {
    if (!await _files.ensureDirectoryAccess(path)) return;
    if (FileService.isTextPath(path)) {
      await _controller.openText(path);
      return;
    }
    if (!path.toLowerCase().endsWith('.tnote')) {
      await _message('このファイル形式は開けません。対応形式は .tnote、.txt、.md、.log です。');
      return;
    }
    final currentPath = _controller.workspacePath;
    if (_controller.workspaceDocuments.isNotEmpty &&
        (currentPath == null || !p.equals(currentPath, path))) {
      if (!await _closeWorkspace()) return;
    }
    try {
      await _controller.open(path);
    } on FileAlreadyOpen catch (error) {
      if (!mounted) return;
      final openReadOnly = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('読み取り専用で開きますか？'),
          content: Text(
            '${error.toString()}\n\n同じ.tnoteファイルを別のWindows PCまたはMacBookで同時に開いています。'
            '後から開く側では編集と上書き保存ができません。読み取り専用で開きますか？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('いいえ'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('はい'),
            ),
          ],
        ),
      );
      if (openReadOnly == true) await _controller.open(path, readOnly: true);
    }
  }

  Future<void> _shareDocument(
    NoteDocument doc, {
    required bool all,
    required bool markdown,
  }) async {
    final source = context.findRenderObject() as RenderBox?;
    await _share.share(doc, all: all, markdown: markdown, source: source);
  }

  Future<void> _open() async {
    final path = await _files.pickOpen();
    if (path != null) await _openPath(path);
  }

  Future<void> _openInNewWindow() async {
    final path = await _files.pickOpen();
    if (path != null) await _files.openNewWindow(path);
  }

  Future<bool> _save(NoteDocument doc, {bool saveAs = false}) async {
    if (doc.isPlainText) {
      if (_files.usesMobileDocumentPicker &&
          (saveAs || doc.sourcePath == null)) {
        final directory = await getTemporaryDirectory();
        final extension = p.extension(doc.name).isEmpty
            ? '.txt'
            : p.extension(doc.name);
        final fileName = p.extension(doc.name).isEmpty
            ? '${doc.name}$extension'
            : doc.name;
        final staging = p.join(
          directory.path,
          'tnote-${DateTime.now().microsecondsSinceEpoch}$extension',
        );
        try {
          await _controller.textFiles.write(
            staging,
            doc.activeTab.text,
            encoding: doc.textEncoding,
          );
          final destination = await _files.savePreparedFile(staging, fileName);
          if (destination == null) return false;
          return await _controller.saveExternalText(
            doc,
            destination: destination,
          );
        } finally {
          final file = File(staging);
          if (await file.exists()) await file.delete();
        }
      }
      String? destination;
      if (saveAs || doc.sourcePath == null) {
        destination = await _files.pickTextSave(doc.name, doc.sourcePath);
        if (destination == null) return false;
      }
      final saved = await _controller.saveExternalText(
        doc,
        destination: destination,
      );
      if (!saved && mounted) await _message(doc.error ?? '保存できませんでした。');
      return saved;
    }
    if (_files.usesMobileDocumentPicker && (saveAs || doc.path == null)) {
      final directory = await getTemporaryDirectory();
      final staging = p.join(
        directory.path,
        'tnote-${DateTime.now().microsecondsSinceEpoch}.tnote',
      );
      final snapshots = _controller.workspaceDocuments
          .map((item) => NoteDocument.fromJson(item.toJson()))
          .toList();
      try {
        await _controller.store.saveWorkspace(
          snapshots,
          _controller.current?.id ?? snapshots.first.id,
          staging,
          create: true,
        );
        final workspaceName = _controller.documents.first.name;
        final fileName = workspaceName.toLowerCase().endsWith('.tnote')
            ? workspaceName
            : '$workspaceName.tnote';
        final destination = await _files.savePreparedFile(staging, fileName);
        if (destination == null) return false;
        await _controller.adoptSavedCopy(doc, destination);
        return true;
      } finally {
        final file = File(staging);
        if (await file.exists()) await file.delete();
      }
    }
    String? destination;
    if (saveAs || doc.path == null) {
      destination = await _files.pickSave(
        _controller.documents.first.name,
        _controller.workspacePath,
      );
      if (destination == null) return false;
    }
    final saved = await _controller.save(doc, destination: destination);
    if (!saved && mounted) await _message(doc.error ?? '保存できませんでした。');
    return saved;
  }

  Future<bool> _close(NoteDocument doc) async {
    if (doc.isPlainText) {
      if (doc.requiresSaveConfirmation) {
        final choice = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('「${doc.name}」を保存しますか？'),
            content: const Text('このファイルに未保存の変更があります。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('キャンセル'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'discard'),
                child: const Text('保存しない'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, 'save'),
                child: const Text('保存'),
              ),
            ],
          ),
        );
        if (choice == null) return false;
        if (choice == 'save' && !await _save(doc)) return false;
        await _controller.close(doc, discard: choice == 'discard');
      } else {
        await _controller.close(doc);
      }
      return true;
    }
    return _closeWorkspace();
  }

  Future<bool> _closeWorkspace() async {
    final workspace = _controller.workspaceDocuments;
    if (workspace.isEmpty) return true;
    final doc = workspace.contains(_controller.current)
        ? _controller.current!
        : workspace.first;
    if (_controller.workspaceRequiresSaveConfirmation) {
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('ファイルを保存しますか？'),
          content: const Text('上段のすべてのタイトルと、その中のタブを1つの.tnoteファイルとして保存します。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'discard'),
              child: const Text('保存しない'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'save'),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (choice == null) return false;
      if (choice == 'save' && !await _save(doc)) return false;
      await _controller.closeWorkspace(discard: choice == 'discard');
    } else {
      await _controller.closeWorkspace();
    }
    return true;
  }

  Future<void> _exit() async {
    final started = Stopwatch()..start();
    await _controller.flushAll();
    if (!mounted) return;
    for (final plain in List<NoteDocument>.of(
      _controller.documents.where((doc) => doc.isPlainText),
    )) {
      if (!plain.requiresSaveConfirmation) continue;
      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('「${plain.name}」を保存しますか？'),
          content: const Text('このファイルに未保存の変更があります。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'discard'),
              child: const Text('保存しない'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'save'),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (choice == null) return;
      if (choice == 'save' && !await _save(plain)) return;
      if (choice == 'discard') {
        await _controller.recovery.remove(plain);
      }
    }
    if (_controller.workspaceRequiresSaveConfirmation) {
      if (!await _closeWorkspace()) return;
    }
    await _controller.shutdown();
    if (widget.desktop) {
      if (started.elapsedMilliseconds < 120) {
        await Future<void>.delayed(
          Duration(milliseconds: 120 - started.elapsedMilliseconds),
        );
      }
      if (Platform.isWindows) {
        await windowManager.setPreventClose(false);
        exit(0);
      }
      await PlatformDocumentService.prepareToTerminate();
      await windowManager.destroy();
    }
  }

  Future<void> _search(NoteDocument doc) async {
    final query = TextEditingController();
    var allTabs = true;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final hits = _controller.search(doc, query.text, allTabs: allTabs);
          return AlertDialog(
            title: const Text('検索'),
            content: SizedBox(
              width: 620,
              height: 430,
              child: Column(
                children: [
                  TextField(
                    controller: query,
                    autofocus: true,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      labelText: '日本語を含む検索語',
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  SwitchListTile(
                    title: const Text('すべてのタブを検索'),
                    value: allTabs,
                    onChanged: (value) => setDialogState(() => allTabs = value),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: hits.length,
                      itemBuilder: (context, index) {
                        final hit = hits[index];
                        return ListTile(
                          title: Text(hit.tab.name),
                          subtitle: Text(hit.excerpt),
                          trailing: Text('${hit.position + 1}文字目'),
                          onTap: () {
                            _controller.selectTab(doc, hit.tab.id);
                            Navigator.pop(context);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('閉じる'),
              ),
            ],
          );
        },
      ),
    );
    query.dispose();
  }

  Future<void> _settings() async {
    final settings = _controller.settings;
    var autosave = settings.autosave;
    var interval = settings.autosaveSeconds;
    var generations = settings.backupGenerations;
    var recentLimit = settings.recentLimit;
    var fontSize = settings.defaultFontSize;
    var theme = settings.themeMode;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('設定'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480, maxHeight: 620),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    title: const Text('自動保存'),
                    value: autosave,
                    onChanged: (value) =>
                        setDialogState(() => autosave = value),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: interval,
                    decoration: const InputDecoration(labelText: '自動保存間隔'),
                    items: const [1, 2, 3, 5, 10]
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text('$value秒'),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setDialogState(() => interval = value ?? 2),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: generations,
                    decoration: const InputDecoration(labelText: 'バックアップ世代数'),
                    items: const [5, 10, 20, 50]
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text('$value世代'),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setDialogState(() => generations = value ?? 10),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: recentLimit,
                    decoration: const InputDecoration(labelText: '最近使ったファイル件数'),
                    items: const [10, 20, 30, 50]
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text('$value件'),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setDialogState(() => recentLimit = value ?? 20),
                  ),
                  DropdownButtonFormField<ThemeMode>(
                    initialValue: theme,
                    decoration: const InputDecoration(labelText: 'テーマ'),
                    items: const [
                      DropdownMenuItem(
                        value: ThemeMode.system,
                        child: Text('システム設定'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.light,
                        child: Text('ライト'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.dark,
                        child: Text('ダーク'),
                      ),
                    ],
                    onChanged: (value) =>
                        setDialogState(() => theme = value ?? ThemeMode.system),
                  ),
                  DropdownButtonFormField<double>(
                    initialValue: fontSize,
                    decoration: const InputDecoration(labelText: '標準文字サイズ'),
                    items:
                        const [
                              10.0,
                              11.0,
                              12.0,
                              14.0,
                              16.0,
                              18.0,
                              20.0,
                              24.0,
                              28.0,
                              32.0,
                            ]
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text('${value.toInt()}'),
                              ),
                            )
                            .toList(),
                    onChanged: (value) =>
                        setDialogState(() => fontSize = value ?? 16),
                  ),
                  const Divider(height: 28),
                  ListTile(
                    leading: const Icon(Icons.system_update_alt),
                    title: const Text('アップデートを確認'),
                    subtitle: const Text('Windows版とMac版の共通最新版を確認します。'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.pop(context, false);
                      unawaited(
                        Future<void>.delayed(
                          Duration.zero,
                          () => _checkForUpdates(manual: true),
                        ),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('TNoteについて'),
                    subtitle: Text(
                      'バージョン ${widget.version}　ビルド ${widget.buildNumber}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.pop(context, false);
                      unawaited(
                        Future<void>.delayed(Duration.zero, _showAbout),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.help_outline),
                    title: const Text('簡単な取扱説明'),
                    subtitle: const Text('保存、タブ、書式、OneDriveの使い方を表示します。'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.pop(context, false);
                      unawaited(_showGuide());
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true) {
      settings.update(
        autosave: autosave,
        autosaveSeconds: interval,
        backupGenerations: generations,
        recentLimit: recentLimit,
        defaultFontSize: fontSize,
        themeMode: theme,
      );
      await SettingsService().save(settings);
      _controller.notifyListeners();
    }
  }

  Future<void> _showGuide() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'TNote ${widget.version} 取扱説明',
          key: const ValueKey('guide-title'),
        ),
        content: const SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _GuideSection(
                  'タイトルを作る・ファイルを開く',
                  '最初の「新しいファイル」で作業を始めます。作業中は上部の「タイトルを追加」で上段タイトルを増やせます。「開く」でパソコン、OneDrive、ファイルアプリにある.tnote・txt・md・logを選びます。テキストファイルは1ファイルずつ上段に追加されます。',
                ),
                _GuideSection(
                  '保存',
                  '.tnoteは上段のすべてのタイトルと下段タブを1ファイルに保存します。txt・md・logは選択中の外部ファイルへ直接保存します。「上書き保存」は現在のファイルを更新し、「ファイルに保存」または「名前を付けて保存」は保存先を選びます。',
                ),
                _GuideSection(
                  'iPhone・iPadのメモから取り込む',
                  'Appleのメモで文章を選び、「共有」から「TNoteに追加」を選びます。TNoteが開き、共有した文章が未保存の上段タブとして追加されます。同時に複数件共有しても順番に取り込みます。保存先は保存時に選びます。',
                ),
                _GuideSection(
                  '文字の書式',
                  '文字を選択して、文字サイズ、太字、斜体、下線、文字の色、背景の色を指定します。選択した文字だけを設定値へ戻すときは、文字サイズ一覧の「標準文字サイズを適用」を使います。その他の文字の個別サイズは変わりません。フォントは常に端末のシステム標準です。本文を右クリックすると「コピー」「切り取り」「貼り付け」「すべて選択」を使用できます。「貼り付け」ボタン、WindowsのCtrl+V、MacのCommand+Vにも対応しています。',
                ),
                _GuideSection(
                  '上段タイトルを見る',
                  '上段タイトルがウィンドウに収まらないときは、両端の左右ボタン、マウスホイール、下のスクロールバーで隠れたタイトルへ移動できます。タイトル自体のドラッグは並べ替えに使います。',
                ),
                _GuideSection(
                  '上段タイトルと下段タブ',
                  '上段タイトルと下段タブは、押して切り替え、ドラッグで並べ替えます。右クリックまたは長押しで名前変更・複製・削除ができます。',
                ),
                _GuideSection(
                  '閉じる',
                  '保存後に変更がなければ、×を押すと確認せず終了します。未保存の変更があるファイルだけ、ファイル単位で保存するか確認します。',
                ),
                _GuideSection(
                  'OneDrive',
                  '同じ.tnoteファイルを別端末で開いている場合は読み取り専用の確認が出ます。「はい」で閲覧し、「いいえ」でそのファイルを閉じます。',
                ),
                _GuideSection(
                  'アップデート',
                  '起動するたびに新しいWindows版とMac版を確認します。「後で」を選ぶと次回起動時に再表示します。すぐ確認したい場合は「設定」から「アップデートを確認」を選びます。',
                ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportDocument(
    NoteDocument doc, {
    required bool all,
    required bool markdown,
  }) async {
    final extension = markdown ? 'md' : 'txt';
    if (_files.usesMobileDocumentPicker) {
      final directory = await getTemporaryDirectory();
      final staging = p.join(
        directory.path,
        'tnote-export-${DateTime.now().microsecondsSinceEpoch}.$extension',
      );
      try {
        if (all) {
          await _export.exportAll(doc, staging, markdown: markdown);
        } else {
          await _export.exportTab(doc.activeTab, staging, markdown: markdown);
        }
        await _files.savePreparedFile(
          staging,
          '${all ? '${doc.name}_全タブ' : doc.activeTab.name}.$extension',
        );
      } finally {
        final file = File(staging);
        if (await file.exists()) await file.delete();
      }
      return;
    }
    final path = await _files.pickExport(
      all ? '${doc.name}_全タブ' : doc.activeTab.name,
      extension,
    );
    if (path == null) return;
    if (all) {
      await _export.exportAll(doc, path, markdown: markdown);
    } else {
      await _export.exportTab(doc.activeTab, path, markdown: markdown);
    }
  }

  Future<void> _backups(NoteDocument doc) async {
    final service = _controller.backups;
    if (service == null || doc.path == null) return;
    final entries = await service.list(doc.path!);
    if (!mounted) return;
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('バックアップから復元'),
        content: SizedBox(
          width: 520,
          height: 360,
          child: entries.isEmpty
              ? const Center(child: Text('バックアップはまだありません。'))
              : ListView(
                  children: entries
                      .map(
                        (entry) => ListTile(
                          leading: const Icon(Icons.history),
                          title: Text(entry.createdAt.toLocal().toString()),
                          subtitle: Text(entry.path),
                          onTap: () => Navigator.pop(context, entry.path),
                        ),
                      )
                      .toList(),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
    if (selected != null) await _controller.restoreBackup(selected);
  }

  Future<void> _tabMenu(NoteDocument doc, NoteTab tab, Offset position) async {
    final selection = await showMenu<String>(
      context: context,
      position: _safeMenuPosition(position),
      items: const [
        PopupMenuItem(value: 'rename', child: Text('名前を変更')),
        PopupMenuItem(value: 'duplicate', child: Text('複製')),
        PopupMenuItem(value: 'delete', child: Text('削除')),
      ],
    );
    if (selection == 'rename') await _rename(doc, tab);
    if (selection == 'duplicate') _controller.duplicateTab(doc, tab);
    if (selection == 'delete') await _delete(doc, tab);
  }

  Future<void> _documentMenu(NoteDocument doc, Offset position) async {
    final selection = await showMenu<String>(
      context: context,
      position: _safeMenuPosition(position),
      items: doc.isPlainText
          ? const [
              PopupMenuItem(value: 'save', child: Text('上書き保存')),
              PopupMenuItem(value: 'saveAs', child: Text('名前を付けて保存')),
              PopupMenuItem(value: 'close', child: Text('ファイルを閉じる')),
            ]
          : const [
              PopupMenuItem(value: 'rename', child: Text('名前を変更')),
              PopupMenuItem(value: 'duplicate', child: Text('複製')),
              PopupMenuItem(value: 'delete', child: Text('削除')),
            ],
    );
    if (selection == 'save') await _save(doc);
    if (selection == 'saveAs') await _save(doc, saveAs: true);
    if (selection == 'close') await _close(doc);
    if (selection == 'rename') await _renameDocument(doc);
    if (selection == 'duplicate') _controller.duplicateDocument(doc);
    if (selection == 'delete') await _deleteDocument(doc);
  }

  RelativeRect _safeMenuPosition(Offset position) {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final maxLeft = (overlay.size.width - 180).clamp(8.0, double.infinity);
    final maxTop = (overlay.size.height - 170).clamp(8.0, double.infinity);
    final left = position.dx.clamp(8.0, maxLeft);
    final top = position.dy.clamp(8.0, maxTop);
    return RelativeRect.fromLTRB(
      left,
      top,
      (overlay.size.width - left - 1).clamp(0.0, double.infinity),
      (overlay.size.height - top - 1).clamp(0.0, double.infinity),
    );
  }

  Future<void> _renameDocument(NoteDocument doc) async {
    final name = await _nameDialog('文書名', doc.name);
    if (name != null) _controller.renameDocument(doc, name);
  }

  Future<void> _deleteDocument(NoteDocument doc) async {
    if (doc.isPlainText) {
      await _close(doc);
      return;
    }
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('タイトル「${doc.name}」を削除しますか？'),
        content: const Text('このタイトルと、その中にあるすべてのタブを現在のファイルから削除します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (yes == true) await _controller.deleteDocument(doc);
  }

  Future<String?> _nameDialog(String title, String initial) async {
    final input = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLength: 100,
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () {
              if (input.text.trim().isNotEmpty) {
                Navigator.pop(context, input.text.trim());
              }
            },
            child: const Text('決定'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    return result;
  }

  Future<String?> _tabName(String initial) async {
    return _nameDialog('タブ名', initial);
  }

  Future<void> _add(NoteDocument doc) async {
    final name = await _tabName('タブ${doc.tabs.length + 1}');
    if (name != null) _controller.addTab(doc, name);
  }

  Future<void> _rename(NoteDocument doc, NoteTab tab) async {
    final name = await _tabName(tab.name);
    if (name != null) _controller.renameTab(doc, tab, name);
  }

  Future<void> _delete(NoteDocument doc, NoteTab tab) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('このタブを削除しますか？'),
        content: Text('「${tab.name}」の本文も削除します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (yes == true) _controller.deleteTab(doc, tab);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<DocumentController>();
    final doc = state.current;
    final mac = Platform.isMacOS;
    return CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.keyN, control: !mac, meta: mac): () {
          if (!_busy && !state.workspaceReadOnly) state.create();
        },
        SingleActivator(
          LogicalKeyboardKey.keyO,
          control: !mac,
          meta: mac,
        ): () =>
            _run(_open),
        SingleActivator(
          LogicalKeyboardKey.keyS,
          control: !mac,
          meta: mac,
        ): () => _run(() async {
          if (doc != null) await _save(doc);
        }),
        SingleActivator(
          LogicalKeyboardKey.keyS,
          control: !mac,
          meta: mac,
          shift: true,
        ): () => _run(() async {
          if (doc != null) await _save(doc, saveAs: true);
        }),
        SingleActivator(
          LogicalKeyboardKey.keyF,
          control: !mac,
          meta: mac,
        ): () => _run(() async {
          if (doc != null) await _search(doc);
        }),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              doc == null
                  ? 'TNote'
                  : '$_fileTitle${state.workspaceDirty ? ' *' : ''}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
            ),
            actions: [
              IconButton(
                tooltip: doc == null ? '新しいファイル' : 'タイトルを追加',
                onPressed:
                    _busy || state.workspaceReadOnly || doc?.isPlainText == true
                    ? null
                    : state.create,
                icon: const Icon(Icons.note_add_outlined),
              ),
              IconButton(
                tooltip: '開く',
                onPressed: _busy ? null : () => _run(_open),
                icon: const Icon(Icons.folder_open),
              ),
              IconButton(
                tooltip: '検索',
                onPressed: _busy || doc == null
                    ? null
                    : () => _run(() => _search(doc)),
                icon: const Icon(Icons.search),
              ),
              IconButton(
                tooltip: '取扱説明',
                onPressed: _busy ? null : () => _run(_showGuide),
                icon: const Icon(Icons.help_outline),
              ),
              IconButton(
                tooltip: '保存',
                onPressed: _busy || doc == null || doc.readOnly
                    ? null
                    : () => _run(() async {
                        await _save(doc);
                      }),
                icon: const Icon(Icons.save_outlined),
              ),
              PopupMenuButton<String>(
                enabled: !_busy,
                tooltip: 'ファイル',
                onSelected: (value) => _run(() async {
                  if (value == 'open') await _open();
                  if (value == 'save' && doc != null) {
                    await _save(doc);
                  }
                  if (value == 'saveAs' && doc != null) {
                    await _save(doc, saveAs: true);
                  }
                  if (value == 'close' && doc != null) await _close(doc);
                  if (value == 'newWindow') await _files.openNewWindow();
                  if (value == 'openWindow') await _openInNewWindow();
                  if (value == 'settings') await _settings();
                  if (value == 'guide') await _showGuide();
                  if (value == 'backup' && doc != null) await _backups(doc);
                  if (value == 'favorite' && doc?.storagePath != null) {
                    await state.recents?.toggleFavorite(
                      doc!.storagePath!,
                      limit: state.settings.recentLimit,
                    );
                    state.notifyListeners();
                  }
                  if (value == 'exportTabTxt' && doc != null) {
                    await _exportDocument(doc, all: false, markdown: false);
                  }
                  if (value == 'exportTabMd' && doc != null) {
                    await _exportDocument(doc, all: false, markdown: true);
                  }
                  if (value == 'exportAllTxt' && doc != null) {
                    await _exportDocument(doc, all: true, markdown: false);
                  }
                  if (value == 'exportAllMd' && doc != null) {
                    await _exportDocument(doc, all: true, markdown: true);
                  }
                  if (value == 'shareTabTxt' && doc != null) {
                    await _shareDocument(doc, all: false, markdown: false);
                  }
                  if (value == 'shareTabMd' && doc != null) {
                    await _shareDocument(doc, all: false, markdown: true);
                  }
                  if (value == 'shareAllTxt' && doc != null) {
                    await _shareDocument(doc, all: true, markdown: false);
                  }
                  if (value == 'shareAllMd' && doc != null) {
                    await _shareDocument(doc, all: true, markdown: true);
                  }
                  if (value == 'exit') await _exit();
                }),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'open', child: Text('ファイルを開く')),
                  if (widget.desktop)
                    const PopupMenuItem(
                      value: 'newWindow',
                      child: Text('新しいウィンドウ'),
                    ),
                  if (widget.desktop)
                    const PopupMenuItem(
                      value: 'openWindow',
                      child: Text('別ウィンドウで開く'),
                    ),
                  PopupMenuItem(
                    value: 'save',
                    enabled: doc != null && !doc.readOnly,
                    child: const Text('上書き保存'),
                  ),
                  PopupMenuItem(
                    value: 'saveAs',
                    enabled: doc != null && !doc.readOnly,
                    child: Text(
                      doc?.isPlainText == true ? '名前を付けて保存' : 'ファイルに保存',
                    ),
                  ),
                  PopupMenuItem(
                    value: 'close',
                    enabled: doc != null,
                    child: const Text('ファイルを閉じる'),
                  ),
                  PopupMenuItem(
                    value: 'favorite',
                    enabled: doc?.storagePath != null,
                    child: const Text('お気に入り切替'),
                  ),
                  PopupMenuItem(
                    value: 'backup',
                    enabled: doc?.isPlainText == false && doc?.path != null,
                    child: const Text('バックアップから復元'),
                  ),
                  PopupMenuItem(
                    value: 'exportTabTxt',
                    enabled: doc != null,
                    child: const Text('現在のタブをテキスト形式で書き出す'),
                  ),
                  PopupMenuItem(
                    value: 'exportTabMd',
                    enabled: doc != null,
                    child: const Text('現在のタブをマークダウン形式で書き出す'),
                  ),
                  PopupMenuItem(
                    value: 'exportAllTxt',
                    enabled: doc != null,
                    child: const Text('全タブをテキスト形式で書き出す'),
                  ),
                  PopupMenuItem(
                    value: 'exportAllMd',
                    enabled: doc != null,
                    child: const Text('全タブをマークダウン形式で書き出す'),
                  ),
                  if (Platform.isIOS || Platform.isMacOS)
                    PopupMenuItem(
                      value: 'shareTabTxt',
                      enabled: doc != null,
                      child: const Text('現在のタブをテキスト形式で共有'),
                    ),
                  if (Platform.isIOS || Platform.isMacOS)
                    PopupMenuItem(
                      value: 'shareTabMd',
                      enabled: doc != null,
                      child: const Text('現在のタブをマークダウン形式で共有'),
                    ),
                  if (Platform.isIOS || Platform.isMacOS)
                    PopupMenuItem(
                      value: 'shareAllTxt',
                      enabled: doc != null,
                      child: const Text('全タブをテキスト形式で共有'),
                    ),
                  if (Platform.isIOS || Platform.isMacOS)
                    PopupMenuItem(
                      value: 'shareAllMd',
                      enabled: doc != null,
                      child: const Text('全タブをマークダウン形式で共有'),
                    ),
                  const PopupMenuItem(value: 'settings', child: Text('設定')),
                  const PopupMenuItem(value: 'guide', child: Text('取扱説明')),
                  if (widget.desktop)
                    const PopupMenuItem(value: 'exit', child: Text('終了')),
                ],
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: AbsorbPointer(
            absorbing: _busy,
            child: Column(
              children: [
                if (state.documents.isNotEmpty)
                  SizedBox(
                    height: 56,
                    child: Row(
                      children: [
                        IconButton(
                          key: const ValueKey('document-scroll-left'),
                          tooltip: '左のタイトルを表示',
                          icon: const Icon(Icons.chevron_left),
                          onPressed: () => _scrollDocumentTitles(-240),
                        ),
                        Expanded(
                          child: Listener(
                            onPointerSignal: (event) {
                              if (event is PointerScrollEvent) {
                                final distance = event.scrollDelta.dy != 0
                                    ? event.scrollDelta.dy
                                    : event.scrollDelta.dx;
                                _scrollDocumentTitles(distance);
                              }
                            },
                            child: Scrollbar(
                              controller: _documentScrollController,
                              thumbVisibility: true,
                              scrollbarOrientation: ScrollbarOrientation.bottom,
                              child: ListView(
                                key: const ValueKey('document-title-list'),
                                controller: _documentScrollController,
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                                children: state.documents.indexed.map((entry) {
                                  final index = entry.$1;
                                  final d = entry.$2;
                                  final chip = GestureDetector(
                                    key: ValueKey('document-${d.id}'),
                                    onDoubleTap: d.isPlainText
                                        ? null
                                        : () => _run(() => _renameDocument(d)),
                                    onSecondaryTapDown: (details) => _run(
                                      () => _documentMenu(
                                        d,
                                        details.globalPosition,
                                      ),
                                    ),
                                    onLongPressStart: (details) => _run(
                                      () => _documentMenu(
                                        d,
                                        details.globalPosition,
                                      ),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 6),
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 260,
                                        ),
                                        child: ChoiceChip(
                                          label: Text(
                                            '${d.name}${d.dirty ? ' *' : ''}',
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 20,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          selected: doc == d,
                                          onSelected: (_) =>
                                              state.selectDocument(d),
                                        ),
                                      ),
                                    ),
                                  );
                                  return DragTarget<int>(
                                    onWillAcceptWithDetails: (details) =>
                                        details.data != index,
                                    onAcceptWithDetails: (details) => state
                                        .reorderDocument(details.data, index),
                                    builder:
                                        (
                                          context,
                                          candidateData,
                                          rejectedData,
                                        ) => Draggable<int>(
                                          data: index,
                                          feedback: Material(
                                            elevation: 4,
                                            borderRadius: BorderRadius.circular(
                                              20,
                                            ),
                                            child: Chip(label: Text(d.name)),
                                          ),
                                          child: MouseRegion(
                                            cursor: SystemMouseCursors.grab,
                                            child: chip,
                                          ),
                                        ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('document-scroll-right'),
                          tooltip: '右のタイトルを表示',
                          icon: const Icon(Icons.chevron_right),
                          onPressed: () => _scrollDocumentTitles(240),
                        ),
                      ],
                    ),
                  ),
                if (doc == null)
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.description_outlined, size: 60),
                          const SizedBox(height: 16),
                          const Text(
                            'ひとつのファイルに、いくつものメモ。',
                            style: TextStyle(fontSize: 20),
                          ),
                          const SizedBox(height: 12),
                          const Text('新しく作るか、.tnote／テキストファイルを開いてください。'),
                          const SizedBox(height: 24),
                          FilledButton.icon(
                            onPressed: state.create,
                            icon: const Icon(Icons.add),
                            label: const Text('新しいファイル'),
                          ),
                          TextButton(
                            onPressed: () => _run(_open),
                            child: const Text('ファイルを開く'),
                          ),
                          if (state.recents?.items.isNotEmpty == true) ...[
                            const SizedBox(height: 20),
                            const Text('最近使ったファイル'),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: 620,
                              height: 180,
                              child: ListView(
                                children: state.recents!.items
                                    .map(
                                      (item) => ListTile(
                                        dense: true,
                                        leading: Icon(
                                          item.favorite
                                              ? Icons.star
                                              : Icons.history,
                                        ),
                                        title: Text(
                                          item.path,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        onTap: () =>
                                            _run(() => _openPath(item.path)),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                else ...[
                  if (doc.readOnly)
                    const MaterialBanner(
                      content: Text(
                        'この.tnoteファイルは別の端末で開かれているため、読み取り専用です。編集と上書き保存はできません。',
                      ),
                      actions: [],
                    ),
                  if (doc.externallyModified)
                    MaterialBanner(
                      content: const Text('このファイルは別の端末またはアプリで変更されています。'),
                      actions: [
                        TextButton(
                          onPressed: () => _run(() => state.reload(doc)),
                          child: const Text('外部変更を読み込む'),
                        ),
                        TextButton(
                          onPressed: () => _run(() async {
                            await _save(doc, saveAs: true);
                          }),
                          child: const Text('現在の内容をファイルに保存'),
                        ),
                      ],
                    ),
                  const Divider(height: 1),
                  Expanded(
                    child: Stack(
                      children: [
                        for (final d in state.documents)
                          for (final tab in d.tabs)
                            if (tab.id == d.activeTabId || tab.text.isNotEmpty)
                              Offstage(
                                key: ValueKey('${d.id}/${tab.id}'),
                                offstage: d != doc || tab.id != doc.activeTabId,
                                child: ExcludeFocus(
                                  excluding:
                                      _busy ||
                                      d != doc ||
                                      tab.id != doc.activeTabId,
                                  child: NoteEditor(
                                    tab: tab,
                                    readOnly: d.readOnly,
                                    fontSize: state.settings.defaultFontSize,
                                    onChanged: (delta, plainText) => state
                                        .editRich(d, tab, delta, plainText),
                                  ),
                                ),
                              ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  if (!doc.isPlainText)
                    SizedBox(
                      height: 52,
                      child: Row(
                        children: [
                          Expanded(
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              children: doc.tabs.indexed
                                  .map(
                                    (entry) => DragTarget<int>(
                                      onWillAcceptWithDetails: (details) =>
                                          details.data != entry.$1,
                                      onAcceptWithDetails: (details) =>
                                          state.reorderTab(
                                            doc,
                                            details.data,
                                            entry.$1,
                                          ),
                                      builder:
                                          (
                                            context,
                                            candidateData,
                                            rejectedData,
                                          ) => Draggable<int>(
                                            data: entry.$1,
                                            feedback: Material(
                                              elevation: 4,
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                              child: Chip(
                                                label: Text(entry.$2.name),
                                              ),
                                            ),
                                            child: MouseRegion(
                                              cursor: SystemMouseCursors.grab,
                                              child: Padding(
                                                key: ValueKey(entry.$2.id),
                                                padding: const EdgeInsets.only(
                                                  right: 5,
                                                ),
                                                child: GestureDetector(
                                                  onDoubleTap: () => _run(
                                                    () =>
                                                        _rename(doc, entry.$2),
                                                  ),
                                                  onSecondaryTapDown:
                                                      (details) => _run(
                                                        () => _tabMenu(
                                                          doc,
                                                          entry.$2,
                                                          details
                                                              .globalPosition,
                                                        ),
                                                      ),
                                                  onLongPressStart: (details) =>
                                                      _run(
                                                        () => _tabMenu(
                                                          doc,
                                                          entry.$2,
                                                          details
                                                              .globalPosition,
                                                        ),
                                                      ),
                                                  child: ConstrainedBox(
                                                    constraints:
                                                        const BoxConstraints(
                                                          maxWidth: 240,
                                                        ),
                                                    child: InputChip(
                                                      label: Text(
                                                        entry.$2.name,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: const TextStyle(
                                                          fontSize: 16,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                                      ),
                                                      selected:
                                                          entry.$2.id ==
                                                          doc.activeTabId,
                                                      onPressed: () =>
                                                          state.selectTab(
                                                            doc,
                                                            entry.$2.id,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                          if (!doc.isPlainText)
                            IconButton(
                              tooltip: 'タブを追加',
                              onPressed: () => _run(() => _add(doc)),
                              icon: const Icon(Icons.add),
                            ),
                        ],
                      ),
                    ),
                  Container(
                    width: double.infinity,
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            state.documents.any((item) => item.error != null)
                                ? '保存エラー：${state.documents.firstWhere((item) => item.error != null).error}'
                                : state.documents.any((item) => item.saving)
                                ? '保存中…'
                                : doc.storagePath == null
                                ? '未保存 — 保存先を選んでください'
                                : doc.dirty
                                ? '未保存'
                                : doc.isPlainText
                                ? '保存済み（${doc.textEncoding.toUpperCase()}）'
                                : '保存済み',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color:
                                  state.documents.every(
                                    (item) => item.error == null,
                                  )
                                  ? null
                                  : Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                        Text(
                          '${doc.tabs.length} タブ',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GuideSection extends StatelessWidget {
  const _GuideSection(this.title, this.body);
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(body),
      ],
    ),
  );
}
