import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:window_manager/window_manager.dart';

import '../models/document.dart';
import '../models/editor_position.dart';
import 'excel_format_controls.dart';

class NoteEditor extends StatefulWidget {
  const NoteEditor({
    super.key,
    required this.tab,
    required this.onChanged,
    required this.fontSize,
    required this.readOnly,
    this.active = true,
    this.desktop = false,
    this.restoredPosition,
  });
  final NoteTab tab;
  final void Function(List<dynamic> delta, String plainText) onChanged;
  final double fontSize;
  final bool readOnly;
  final bool active;
  final bool desktop;
  final EditorPosition? restoredPosition;

  @override
  NoteEditorState createState() => NoteEditorState();
}

class NoteEditorState extends State<NoteEditor>
    with WindowListener, WidgetsBindingObserver {
  late final QuillController _controller;
  late final FocusNode _focusNode;
  late final ScrollController _scrollController;
  final _editorKey = GlobalKey<EditorState>();
  final _viewportKey = GlobalKey();
  late List<dynamic> _boundDelta;
  StreamSubscription<DocChange>? _changes;
  Timer? _changeNotification;
  Timer? _dragTimer;
  int? _dragPointer;
  int? _dragAnchor;
  Offset? _pressPosition;
  Offset? _dragPosition;
  bool _menuOpen = false;

  EditorPosition get position => EditorPosition(
    base: _controller.selection.baseOffset,
    extent: _controller.selection.extentOffset,
    scroll: _scrollController.hasClients ? _scrollController.offset : 0,
  );

  bool get inputInProgress {
    final editor = _editorKey.currentState;
    final composing = editor is QuillRawEditorState
        ? editor.composingRange.value
        : TextRange.empty;
    return _dragPointer != null ||
        (composing.isValid && !composing.isCollapsed);
  }

  @override
  void initState() {
    super.initState();
    _boundDelta = widget.tab.delta;
    final document = Document.fromJson(widget.tab.delta);
    final restored = widget.restoredPosition;
    _controller = QuillController(
      document: document,
      selection:
          restored?.selectionFor(document.length - 1) ??
          const TextSelection.collapsed(offset: 0),
      readOnly: widget.readOnly,
    );
    _focusNode = FocusNode(debugLabel: '本文入力欄');
    _scrollController = ScrollController(
      initialScrollOffset: restored?.scroll ?? 0,
    );
    WidgetsBinding.instance.addObserver(this);
    if (widget.desktop) windowManager.addListener(this);
    _listenToDocument();
    if (widget.active && restored == null) _focusWhenActive();
  }

  void _listenToDocument() {
    _changes = _controller.document.changes.listen((_) {
      _changeNotification?.cancel();
      _changeNotification = Timer(Duration.zero, flushEdits);
    });
  }

  void flushEdits() {
    if (!mounted || _changeNotification == null) return;
    _changeNotification?.cancel();
    _changeNotification = null;
    widget.onChanged(
      _controller.document.toDelta().toJson(),
      _controller.document.toPlainText(),
    );
    _boundDelta = widget.tab.delta;
  }

  void _focusWhenActive() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active && widget.restoredPosition == null) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void didUpdateWidget(covariant NoteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.readOnly = widget.readOnly;
    if (!widget.active) _stopDrag();
    if (!oldWidget.active && widget.active && widget.restoredPosition == null) {
      _focusWhenActive();
    }
    if (!identical(_boundDelta, widget.tab.delta)) {
      // Save notifications leave this model unchanged. Only a true reload
      // replaces the document, keeping the viewport and clamping selection.
      final before = position;
      final previous = _controller.document;
      _changeNotification?.cancel();
      _changeNotification = null;
      unawaited(_changes?.cancel());
      _boundDelta = widget.tab.delta;
      final incoming = Document.fromJson(_boundDelta);
      _controller.ignoreFocusOnTextChange = true;
      try {
        _controller.document = incoming;
        _controller.updateSelection(
          before.selectionFor(incoming.length - 1),
          ChangeSource.remote,
        );
      } finally {
        _controller.ignoreFocusOnTextChange = false;
      }
      _listenToDocument();
      previous.close();
    }
    final restored = widget.restoredPosition;
    if (restored != null && !identical(oldWidget.restoredPosition, restored)) {
      _controller.ignoreFocusOnTextChange = true;
      try {
        _controller.updateSelection(
          restored.selectionFor(_controller.document.length - 1),
          ChangeSource.remote,
        );
      } finally {
        _controller.ignoreFocusOnTextChange = false;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        final scroll = _scrollController.position;
        scroll.jumpTo(
          restored.scroll.clamp(scroll.minScrollExtent, scroll.maxScrollExtent),
        );
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.desktop) windowManager.removeListener(this);
    _stopDrag();
    _changes?.cancel();
    _changeNotification?.cancel();
    _focusNode.dispose();
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  void onWindowBlur() => _stopDrag();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _stopDrag();
  }

  void _pointerDown(PointerDownEvent event) {
    if (!widget.active || event.kind != PointerDeviceKind.mouse) return;
    if (event.buttons == kSecondaryMouseButton) {
      _stopDrag();
      unawaited(_showEditMenu(event.position));
      return;
    }
    if (event.buttons != kPrimaryMouseButton) return;
    final renderer = _editorKey.currentState?.renderEditor;
    if (renderer == null || !renderer.attached) return;
    _dragPointer = event.pointer;
    _pressPosition = event.position;
    _dragAnchor = renderer.getPositionForOffset(event.position).offset;
  }

  void _pointerMove(PointerMoveEvent event) {
    if (event.pointer != _dragPointer) return;
    if (event.buttons != kPrimaryMouseButton) {
      _stopDrag();
      return;
    }
    if (_dragPosition == null &&
        (event.position - _pressPosition!).distance < 4) {
      return;
    }
    _dragPosition = event.position;
    if (_dragSpeed() == 0) {
      _dragTimer?.cancel();
      _dragTimer = null;
      return;
    }
    _dragTimer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      _scrollDrag,
    );
  }

  double _dragSpeed() {
    final point = _dragPosition;
    final box = _viewportKey.currentContext?.findRenderObject();
    if (!widget.active || point == null || box is! RenderBox || !box.hasSize) {
      return 0;
    }
    final local = box.globalToLocal(point);
    if (local.dx < -48 || local.dx > box.size.width + 48) return 0;
    const edge = 36.0;
    if (local.dy < edge) return -((edge - local.dy) / edge).clamp(0, 1) * 13;
    final bottom = box.size.height - local.dy;
    if (bottom < edge) return ((edge - bottom) / edge).clamp(0, 1) * 13;
    return 0;
  }

  void _scrollDrag(Timer timer) {
    final speed = _dragSpeed();
    if (speed == 0 || !_scrollController.hasClients) {
      timer.cancel();
      _dragTimer = null;
      return;
    }
    final scroll = _scrollController.position;
    final next = (scroll.pixels + speed).clamp(
      scroll.minScrollExtent,
      scroll.maxScrollExtent,
    );
    if (next != scroll.pixels) scroll.jumpTo(next);
    final atStart = speed < 0 && next == scroll.minScrollExtent;
    final atEnd = speed > 0 && next == scroll.maxScrollExtent;
    final pointer = _dragPointer;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _dragPointer != pointer ||
          _dragPosition == null ||
          _dragSpeed() == 0) {
        return;
      }
      final box = _viewportKey.currentContext?.findRenderObject();
      final editor = _editorKey.currentState?.renderEditor;
      if (box is! RenderBox || editor == null || !editor.attached) return;
      final local = box.globalToLocal(_dragPosition!);
      final target = box.localToGlobal(
        Offset(
          local.dx.clamp(0, box.size.width),
          local.dy.clamp(0, box.size.height - 1),
        ),
      );
      final end = _controller.document.length - 1;
      final offset = atStart
          ? 0
          : atEnd
          ? end
          : editor.getPositionForOffset(target).offset;
      final selection = TextSelection(
        baseOffset: _dragAnchor!.clamp(0, end),
        extentOffset: offset.clamp(0, end),
      );
      if (_controller.selection != selection) {
        _controller.updateSelection(selection, ChangeSource.local);
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _pointerEnd(PointerEvent event) {
    if (event.pointer == _dragPointer) _stopDrag();
  }

  void _stopDrag() {
    _dragTimer?.cancel();
    _dragTimer = null;
    _dragPointer = null;
    _dragAnchor = null;
    _pressPosition = null;
    _dragPosition = null;
  }

  Future<void> _paste() async {
    if (widget.readOnly) return;
    String? text;
    // Excel can keep the Windows clipboard busy briefly while rendering cells.
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      } on PlatformException {
        text = null;
      }
      if (text != null && text.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    if (!mounted || !widget.active || text == null || text.isEmpty) return;
    text = text
        .replaceAll('\u0000', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final selection = _controller.selection;
    final start = selection.isValid
        ? selection.start.clamp(0, _controller.document.length - 1)
        : _controller.document.length - 1;
    final length = selection.isValid && !selection.isCollapsed
        ? selection.end - selection.start
        : 0;
    _controller.replaceText(
      start,
      length,
      text,
      TextSelection.collapsed(offset: start + text.length),
    );
    _focusNode.requestFocus();
  }

  bool get _hasSelection {
    final selection = _controller.selection;
    return selection.isValid && !selection.isCollapsed;
  }

  Future<void> _copySelection() async {
    if (!_hasSelection) return;
    final selection = _controller.selection;
    final text = _controller.document.toPlainText();
    final start = selection.start.clamp(0, text.length);
    final end = selection.end.clamp(start, text.length);
    await Clipboard.setData(ClipboardData(text: text.substring(start, end)));
  }

  Future<void> _cutSelection() async {
    if (widget.readOnly || !_hasSelection) return;
    final selection = _controller.selection;
    await _copySelection();
    _controller.replaceText(
      selection.start,
      selection.end - selection.start,
      '',
      TextSelection.collapsed(offset: selection.start),
    );
    _focusNode.requestFocus();
  }

  void _selectAll() {
    final end = (_controller.document.length - 1).clamp(
      0,
      _controller.document.length,
    );
    _controller.updateSelection(
      TextSelection(baseOffset: 0, extentOffset: end),
      ChangeSource.local,
    );
    _focusNode.requestFocus();
  }

  Future<void> _showEditMenu(Offset position) async {
    if (_menuOpen) return;
    _menuOpen = true;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final local = overlay.globalToLocal(position);
    final selected = await showMenu<String>(
      context: context,
      requestFocus: false,
      position: RelativeRect.fromRect(
        Rect.fromPoints(local, local),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: 'copy',
          enabled: _hasSelection,
          child: const Text('コピー'),
        ),
        PopupMenuItem(
          value: 'cut',
          enabled: _hasSelection && !widget.readOnly,
          child: const Text('切り取り'),
        ),
        PopupMenuItem(
          value: 'paste',
          enabled: !widget.readOnly,
          child: const Text('貼り付け'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'selectAll', child: Text('すべて選択')),
      ],
    ).whenComplete(() => _menuOpen = false);
    if (!mounted) return;
    if (selected == 'copy') await _copySelection();
    if (selected == 'cut') await _cutSelection();
    if (selected == 'paste') await _paste();
    if (selected == 'selectAll') _selectAll();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      SingleActivator(
        LogicalKeyboardKey.keyC,
        control: defaultTargetPlatform != TargetPlatform.macOS,
        meta: defaultTargetPlatform == TargetPlatform.macOS,
      ): () =>
          unawaited(_copySelection()),
      SingleActivator(
        LogicalKeyboardKey.keyV,
        control: defaultTargetPlatform != TargetPlatform.macOS,
        meta: defaultTargetPlatform == TargetPlatform.macOS,
      ): () =>
          unawaited(_paste()),
    },
    child: Column(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: IgnorePointer(
            ignoring: widget.readOnly,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final formats = ExcelFormatControls(
                  controller: _controller,
                  editorFocusNode: _focusNode,
                  defaultFontSize: widget.fontSize,
                );
                final toolbar = QuillSimpleToolbar(
                  controller: _controller,
                  config: QuillSimpleToolbarConfig(
                    multiRowsDisplay: false,
                    showFontFamily: false,
                    showFontSize: false,
                    showColorButton: false,
                    showBackgroundColorButton: false,
                    showStrikeThrough: false,
                    showInlineCode: false,
                    showSmallButton: false,
                    showSubscript: false,
                    showSuperscript: false,
                    showCodeBlock: false,
                    showQuote: false,
                    showIndent: false,
                    showLink: false,
                    showListCheck: false,
                    showDirection: false,
                    showSearchButton: false,
                    showAlignmentButtons: true,
                    buttonOptions: QuillSimpleToolbarButtonOptions(
                      undoHistory: const QuillToolbarHistoryButtonOptions(
                        tooltip: '元に戻す',
                      ),
                      redoHistory: const QuillToolbarHistoryButtonOptions(
                        tooltip: 'やり直す',
                      ),
                      bold: const QuillToolbarToggleStyleButtonOptions(
                        tooltip: '太字',
                      ),
                      italic: const QuillToolbarToggleStyleButtonOptions(
                        tooltip: '斜体',
                      ),
                      underLine: const QuillToolbarToggleStyleButtonOptions(
                        tooltip: '下線',
                      ),
                      clearFormat: const QuillToolbarClearFormatButtonOptions(
                        tooltip: '書式を解除',
                      ),
                      selectHeaderStyleDropdownButton:
                          const QuillToolbarSelectHeaderStyleDropdownButtonOptions(
                            tooltip: '見出し',
                            defaultDisplayText: '標準',
                          ),
                      listNumbers: const QuillToolbarToggleStyleButtonOptions(
                        tooltip: '番号付き一覧',
                      ),
                      listBullets: const QuillToolbarToggleStyleButtonOptions(
                        tooltip: '箇条書き',
                      ),
                      selectAlignmentButtons:
                          const QuillToolbarSelectAlignmentButtonOptions(
                            tooltips: QuillSelectAlignmentValues(
                              leftAlignment: '左揃え',
                              centerAlignment: '中央揃え',
                              rightAlignment: '右揃え',
                              justifyAlignment: '両端揃え',
                            ),
                          ),
                    ),
                  ),
                );
                if (constraints.maxWidth < 760) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: 44,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Row(
                            children: [
                              IconButton(
                                tooltip: '貼り付け',
                                onPressed: _paste,
                                icon: const Icon(Icons.content_paste),
                              ),
                              formats,
                            ],
                          ),
                        ),
                      ),
                      toolbar,
                    ],
                  );
                }
                return Row(
                  children: [
                    IconButton(
                      tooltip: '貼り付け',
                      onPressed: _paste,
                      icon: const Icon(Icons.content_paste),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: formats,
                    ),
                    const VerticalDivider(width: 8),
                    Expanded(child: toolbar),
                  ],
                );
              },
            ),
          ),
        ),
        Expanded(
          child: Listener(
            key: _viewportKey,
            behavior: HitTestBehavior.translucent,
            onPointerDown: _pointerDown,
            onPointerMove: _pointerMove,
            onPointerUp: _pointerEnd,
            onPointerCancel: _pointerEnd,
            child: QuillEditor(
              controller: _controller,
              focusNode: _focusNode,
              scrollController: _scrollController,
              config: QuillEditorConfig(
                editorKey: _editorKey,
                enableInteractiveSelection: true,
                enableSelectionToolbar: false,
                onTapOutside: (event, focus) {
                  if (!_menuOpen &&
                      (widget.desktop ||
                          event.kind != PointerDeviceKind.touch)) {
                    focus.unfocus();
                  }
                },
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 18,
                ),
                expands: true,
                placeholder: 'ここから書き始めましょう。',
                customStyles: DefaultStyles(
                  paragraph: DefaultTextBlockStyle(
                    TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: widget.fontSize,
                      height: 1.45,
                    ),
                    const HorizontalSpacing(0, 0),
                    const VerticalSpacing(6, 0),
                    const VerticalSpacing(0, 0),
                    null,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
