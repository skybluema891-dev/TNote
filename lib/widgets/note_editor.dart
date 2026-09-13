import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../models/document.dart';
import 'excel_format_controls.dart';

class NoteEditor extends StatefulWidget {
  const NoteEditor({
    super.key,
    required this.tab,
    required this.onChanged,
    required this.fontSize,
    required this.readOnly,
  });
  final NoteTab tab;
  final void Function(List<dynamic> delta, String plainText) onChanged;
  final double fontSize;
  final bool readOnly;

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  late final QuillController _controller;
  late final FocusNode _focusNode;
  late final ScrollController _scrollController;
  StreamSubscription<DocChange>? _changes;
  Timer? _changeNotification;

  @override
  void initState() {
    super.initState();
    final document = Document.fromJson(widget.tab.delta);
    _controller = QuillController(
      document: document,
      selection: TextSelection.collapsed(
        offset: (document.length - 1).clamp(0, document.length),
      ),
      readOnly: widget.readOnly,
    );
    _focusNode = FocusNode(debugLabel: '本文入力欄');
    _scrollController = ScrollController();
    _changes = _controller.document.changes.listen((_) {
      _changeNotification?.cancel();
      _changeNotification = Timer(Duration.zero, () {
        if (!mounted) return;
        widget.onChanged(
          _controller.document.toDelta().toJson(),
          _controller.document.toPlainText(),
        );
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _changes?.cancel();
    _changeNotification?.cancel();
    _focusNode.dispose();
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    if (widget.readOnly) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
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

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      SingleActivator(
        LogicalKeyboardKey.keyV,
        control: defaultTargetPlatform != TargetPlatform.macOS,
        meta: defaultTargetPlatform == TargetPlatform.macOS,
      ): () =>
          unawaited(_paste()),
    },
    child: Focus(
      autofocus: true,
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
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => _focusNode.requestFocus(),
              child: QuillEditor(
                controller: _controller,
                focusNode: _focusNode,
                scrollController: _scrollController,
                config: QuillEditorConfig(
                  autoFocus: true,
                  enableInteractiveSelection: !widget.readOnly,
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
    ),
  );
}
