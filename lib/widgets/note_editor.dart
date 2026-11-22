import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:dart_quill_delta/dart_quill_delta.dart' as q;
import 'package:window_manager/window_manager.dart';

import '../models/document.dart';
import '../models/editor_position.dart';
import 'excel_format_controls.dart';

// Quill requests its own caret scrolling while processing mouse selection.
// During an edge drag the pointer drives the position directly.
class _NoteScrollController extends ScrollController {
  _NoteScrollController({required super.initialScrollOffset});
  bool edgeSelecting = false;

  @override
  void jumpTo(double value) {
    if (!edgeSelecting) super.jumpTo(value);
  }

  @override
  Future<void> animateTo(
    double offset, {
    required Duration duration,
    required Curve curve,
  }) {
    if (edgeSelecting) return Future<void>.value();
    return super.animateTo(offset, duration: duration, curve: curve);
  }
}

class _EdgeDrag {
  _EdgeDrag(this.direction, this.offset, this.previousIgnoreFocus);
  final double direction;
  final bool previousIgnoreFocus;
  double offset;
  int? extent;
  int lastTick = 0;
  bool framePending = false;
}

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
    this.onOperation,
  });
  final NoteTab tab;
  final void Function(List<dynamic> delta, String plainText) onChanged;
  final double fontSize;
  final bool readOnly;
  final bool active;
  final bool desktop;
  final EditorPosition? restoredPosition;
  final void Function(List<dynamic> operations)? onOperation;

  @override
  NoteEditorState createState() => NoteEditorState();
}

class NoteEditorState extends State<NoteEditor>
    with WindowListener, WidgetsBindingObserver {
  late final QuillController _controller;
  late final FocusNode _focusNode;
  late final _NoteScrollController _scrollController;
  final _editorKey = GlobalKey<EditorState>();
  final _viewportKey = GlobalKey();
  late List<dynamic> _boundDelta;
  StreamSubscription<DocChange>? _changes;
  Timer? _changeNotification;
  Timer? _dragTimer;
  _EdgeDrag? _edge;
  int? _dragPointer;
  int? _dragAnchor;
  Offset? _pressPosition;
  Offset? _dragPosition;
  bool _menuOpen = false;
  ({TextPosition text, double y, double scroll})? _readingAnchor;

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
    _focusNode = FocusNode(debugLabel: '本文入力欄')
      ..addListener(_onEditorFocusChanged);
    _scrollController = _NoteScrollController(
      initialScrollOffset: restored?.scroll ?? 0,
    );
    WidgetsBinding.instance.addObserver(this);
    if (widget.desktop) windowManager.addListener(this);
    _listenToDocument();
    if (widget.onOperation != null) _controller.addListener(_publishLocal);
    if (widget.active && restored == null) _focusWhenActive();
  }

  void _listenToDocument() {
    _changes = _controller.document.changes.listen((change) {
      if (widget.onOperation != null || change.source == ChangeSource.remote) {
        return;
      }
      _changeNotification?.cancel();
      _changeNotification = Timer(Duration.zero, flushEdits);
    });
  }

  bool _receiving = false;
  void _publishLocal() {
    if (_receiving) return;
    _readingAnchor = null;
    if (widget.readOnly) return;
    final before = q.Delta.fromJson(_boundDelta);
    final after = _controller.document.toDelta();
    if (before == after) return;
    final operations = before.diff(after, cleanupSemantic: false);
    if (operations.isEmpty) return;
    widget.onOperation?.call(operations.toJson());
    _boundDelta = after.toJson();
    widget.tab.delta = _boundDelta;
  }

  /// The caller delays delivery while the IME or a selection drag is active.
  void receiveOperations(List<dynamic> operations) {
    final change = q.Delta.fromJson(operations);
    if (change.isEmpty) return;
    _trackReadingPosition(change);
    _receiving = true;
    final history = _controller.document.history;
    final ignore = history.ignoreChange;
    final focus = _controller.ignoreFocusOnTextChange;
    try {
      history.ignoreChange = true;
      _controller.ignoreFocusOnTextChange = true;
      final selection = _controller.selection;
      _controller.compose(change, selection, ChangeSource.remote);
      // Exclude text another writer inserts exactly at either selection edge.
      // Quill already transforms the end and a collapsed insertion point.
      if (selection.isValid && !selection.isCollapsed) {
        final start = change.transformPosition(selection.start);
        final current = _controller.selection;
        final kept = selection.baseOffset < selection.extentOffset
            ? current.copyWith(baseOffset: start)
            : current.copyWith(extentOffset: start);
        if (kept != current) {
          _controller.updateSelection(kept, ChangeSource.remote);
        }
      }
      history.transform(change);
      history.lastRecorded = 0;
      _boundDelta = _controller.document.toDelta().toJson();
      widget.tab.delta = _boundDelta;
    } finally {
      history.ignoreChange = ignore;
      _controller.ignoreFocusOnTextChange = focus;
      _receiving = false;
    }
    setState(() {});
  }

  // Remember text at the viewport edge. A pixel offset alone would show a
  // different paragraph after another writer adds or removes lines above it.
  void _trackReadingPosition(q.Delta change) {
    var anchor = _readingAnchor;
    if (anchor == null) {
      final box = _viewportKey.currentContext?.findRenderObject();
      final editor = _editorKey.currentState?.renderEditor;
      if (!widget.active ||
          !_scrollController.hasClients ||
          _controller.document.length <= 1 ||
          box is! RenderBox ||
          !box.hasSize ||
          editor == null ||
          !editor.attached) {
        return;
      }
      final text = editor.getPositionForOffset(
        box.localToGlobal(const Offset(25, 1)),
      );
      final caret = editor.getLocalRectForCaret(text);
      final y = box.globalToLocal(editor.localToGlobal(caret.topLeft)).dy;
      anchor = (text: text, y: y, scroll: _scrollController.offset);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _restoreReadingPosition(),
      );
    }
    final selection = _controller.selection;
    final atCaret =
        _focusNode.hasFocus &&
        selection.isCollapsed &&
        selection.extentOffset == anchor.text.offset;
    _readingAnchor = (
      text: TextPosition(
        offset: change.transformPosition(anchor.text.offset, force: !atCaret),
        affinity: anchor.text.affinity,
      ),
      y: anchor.y,
      scroll: anchor.scroll,
    );
  }

  void _restoreReadingPosition() {
    final anchor = _readingAnchor;
    _readingAnchor = null;
    if (anchor == null ||
        !mounted ||
        !widget.active ||
        !_scrollController.hasClients) {
      return;
    }
    final box = _viewportKey.currentContext?.findRenderObject();
    final editor = _editorKey.currentState?.renderEditor;
    if (box is! RenderBox ||
        !box.hasSize ||
        editor == null ||
        !editor.attached) {
      return;
    }
    final scroll = _scrollController.position;
    // The user can wheel-scroll between receiving the change and layout.
    final prior = anchor.scroll.clamp(
      scroll.minScrollExtent,
      scroll.maxScrollExtent,
    );
    if ((scroll.pixels - prior).abs() > 0.5) return;
    final text = TextPosition(
      offset: anchor.text.offset.clamp(0, _controller.document.length - 1),
      affinity: anchor.text.affinity,
    );
    final caret = editor.getLocalRectForCaret(text);
    final y = box.globalToLocal(editor.localToGlobal(caret.topLeft)).dy;
    final next = (scroll.pixels + y - anchor.y).clamp(
      scroll.minScrollExtent,
      scroll.maxScrollExtent,
    );
    if ((next - scroll.pixels).abs() > 0.5) scroll.jumpTo(next);
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

  void revealMatch(int start, int length) {
    if (!widget.active) return;
    _readingAnchor = null;
    final end = _controller.document.length - 1;
    final selection = TextSelection(
      baseOffset: start.clamp(0, end),
      extentOffset: (start + length).clamp(0, end),
    );
    _focusNode.requestFocus();
    _controller.updateSelection(selection, ChangeSource.local);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !widget.active ||
          _controller.selection != selection ||
          !_scrollController.hasClients) {
        return;
      }
      final viewport = _viewportKey.currentContext?.findRenderObject();
      final editor = _editorKey.currentState?.renderEditor;
      if (viewport is! RenderBox ||
          !viewport.hasSize ||
          editor == null ||
          !editor.attached) {
        return;
      }
      final caret = editor.getLocalRectForCaret(selection.base);
      final top = viewport
          .globalToLocal(editor.localToGlobal(caret.topLeft))
          .dy;
      final bottom = top + caret.height;
      const inset = 12.0;
      final offset = _scrollController.position;
      if (top < inset || bottom > viewport.size.height - inset) {
        final target = offset.pixels + top - inset;
        _scrollController.jumpTo(
          target.clamp(offset.minScrollExtent, offset.maxScrollExtent),
        );
      }
    });
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
    if (!widget.active) {
      _readingAnchor = null;
      _stopDrag();
    }
    if (!oldWidget.active && widget.active && widget.restoredPosition == null) {
      _focusWhenActive();
    }
    if (widget.onOperation == null &&
        !identical(_boundDelta, widget.tab.delta)) {
      _boundDelta = widget.tab.delta;
      if (_controller.document.toDelta() != q.Delta.fromJson(_boundDelta)) {
        _reloadDocument();
      }
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

  void _reloadDocument() {
    final before = position;
    final previous = _controller.document;
    _changeNotification?.cancel();
    _changeNotification = null;
    unawaited(_changes?.cancel());
    final incoming = Document.fromJson(_boundDelta);
    final ignore = _controller.ignoreFocusOnTextChange;
    _controller.ignoreFocusOnTextChange = true;
    try {
      _controller.document = incoming;
      _controller.updateSelection(
        before.selectionFor(incoming.length - 1),
        ChangeSource.remote,
      );
    } finally {
      _controller.ignoreFocusOnTextChange = ignore;
    }
    _listenToDocument();
    previous.close();
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

  void _onEditorFocusChanged() {
    if (!_focusNode.hasFocus) _stopDrag();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _stopDrag();
  }

  void _pointerDown(PointerDownEvent event) {
    _readingAnchor = null;
    if (!widget.active || event.kind != PointerDeviceKind.mouse) return;
    if (event.buttons == kSecondaryMouseButton) {
      _stopDrag();
      unawaited(_showEditMenu(event.position));
      return;
    }
    if (event.buttons != kPrimaryMouseButton) return;
    final renderer = _editorKey.currentState?.renderEditor;
    if (renderer == null || !renderer.attached) return;
    // Starting in the text margin must also route Ctrl/Cmd+C to this editor.
    if (!_focusNode.hasFocus) _focusNode.requestFocus();
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
    final speed = _dragSpeed();
    if (speed == 0 || !_scrollController.hasClients) {
      _stopEdge();
      return;
    }
    if (_edge?.direction == speed.sign) return;
    _stopEdge();
    final scroll = _scrollController.position;
    _edge = _EdgeDrag(
      speed.sign,
      scroll.pixels,
      _controller.ignoreFocusOnTextChange,
    );
    _controller.ignoreFocusOnTextChange = true;
    _scrollController.edgeSelecting = true;
    scroll.jumpTo(scroll.pixels); // Stop any caret animation already in flight.
    FocusManager.instance.addEarlyKeyEventHandler(_keyDuringEdge);
    _dragTimer = Timer.periodic(const Duration(milliseconds: 16), _scrollDrag);
  }

  KeyEventResult _keyDuringEdge(KeyEvent event) {
    if (event is KeyDownEvent) _stopDrag();
    return KeyEventResult.ignored;
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
    final edge = _edge;
    final speed = _dragSpeed();
    if (edge == null ||
        speed.sign != edge.direction ||
        !_scrollController.hasClients) {
      _stopEdge();
      return;
    }
    // Advancing the previous target also recovers if layout adjusted pixels
    // between ticks. A caret reveal must never restart a drag from earlier text.
    final scroll = _scrollController.position;
    final elapsedTicks = (timer.tick - edge.lastTick).clamp(1, 4);
    edge.lastTick = timer.tick;
    edge.offset = (edge.offset + speed * elapsedTicks).clamp(
      scroll.minScrollExtent,
      scroll.maxScrollExtent,
    );
    if (scroll.pixels != edge.offset) scroll.jumpTo(edge.offset);
    if (edge.framePending) return;
    edge.framePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      edge.framePending = false;
      if (mounted && identical(_edge, edge)) _extendEdgeSelection(edge);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _extendEdgeSelection(_EdgeDrag edge) {
    final box = _viewportKey.currentContext?.findRenderObject();
    final editor = _editorKey.currentState?.renderEditor;
    if (box is! RenderBox || editor == null || !editor.attached) return;
    final scroll = _scrollController.position;
    final end = _controller.document.length - 1;
    final local = box.globalToLocal(_dragPosition!);
    final point = box.localToGlobal(
      Offset(
        local.dx.clamp(0, box.size.width),
        local.dy.clamp(0, box.size.height - 1),
      ),
    );
    var extent = editor.getPositionForOffset(point).offset.clamp(0, end);
    if (edge.direction > 0) {
      extent = edge.offset >= scroll.maxScrollExtent
          ? end
          : extent.clamp(edge.extent ?? 0, end);
    } else {
      extent = edge.offset <= scroll.minScrollExtent
          ? 0
          : extent.clamp(0, edge.extent ?? end);
    }
    edge.extent = extent;
    final selection = TextSelection(
      baseOffset: _dragAnchor!.clamp(0, end),
      extentOffset: extent,
    );
    if (_controller.selection != selection) {
      _controller.updateSelection(selection, ChangeSource.local);
      setState(() {});
    }
  }

  void _pointerEnd(PointerEvent event) {
    if (event.pointer != _dragPointer) return;
    final edge = _edge;
    if (event is PointerUpEvent &&
        edge != null &&
        _scrollController.hasClients) {
      final scroll = _scrollController.position;
      if (scroll.pixels != edge.offset) scroll.jumpTo(edge.offset);
      _extendEdgeSelection(edge);
    }
    _stopDrag();
  }

  void _stopEdge() {
    _dragTimer?.cancel();
    _dragTimer = null;
    final edge = _edge;
    if (edge == null) return;
    _edge = null;
    FocusManager.instance.removeEarlyKeyEventHandler(_keyDuringEdge);
    _scrollController.edgeSelecting = false;
    _controller.ignoreFocusOnTextChange = edge.previousIgnoreFocus;
  }

  void _stopDrag() {
    _stopEdge();
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
            onPointerSignal: (_) {
              _readingAnchor = null;
              _stopDrag();
            },
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
