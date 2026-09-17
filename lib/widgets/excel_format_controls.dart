import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';

class ExcelFormatControls extends StatefulWidget {
  const ExcelFormatControls({
    super.key,
    required this.controller,
    required this.editorFocusNode,
    required this.defaultFontSize,
  });

  final QuillController controller;
  final FocusNode editorFocusNode;
  final double defaultFontSize;

  @override
  State<ExcelFormatControls> createState() => _ExcelFormatControlsState();
}

class _ExcelFormatControlsState extends State<ExcelFormatControls> {
  static const _fontSizes = <double>[
    8,
    9,
    10,
    11,
    12,
    14,
    16,
    18,
    20,
    22,
    24,
    26,
    28,
    32,
    36,
    48,
    72,
  ];
  static const _themeColors = <List<_PaletteColor>>[
    [
      _PaletteColor('白', '#ffffff'),
      _PaletteColor('黒', '#000000'),
      _PaletteColor('薄い灰色', '#e7e6e6'),
      _PaletteColor('濃い青', '#44546a'),
      _PaletteColor('青', '#4472c4'),
      _PaletteColor('オレンジ', '#ed7d31'),
      _PaletteColor('灰色', '#a5a5a5'),
      _PaletteColor('黄', '#ffc000'),
      _PaletteColor('薄い青', '#5b9bd5'),
      _PaletteColor('緑', '#70ad47'),
    ],
    [
      _PaletteColor('白、背景1、黒を5%', '#f2f2f2'),
      _PaletteColor('黒、文字1、白を95%', '#f2f2f2'),
      _PaletteColor('薄い灰色、白を80%', '#f4f3f3'),
      _PaletteColor('濃い青、白を80%', '#d6dce4'),
      _PaletteColor('青、白を80%', '#d9e2f3'),
      _PaletteColor('オレンジ、白を80%', '#fce4d6'),
      _PaletteColor('灰色、白を80%', '#ededed'),
      _PaletteColor('黄、白を80%', '#fff2cc'),
      _PaletteColor('薄い青、白を80%', '#ddebf7'),
      _PaletteColor('緑、白を80%', '#e2f0d9'),
    ],
    [
      _PaletteColor('白、背景1、黒を15%', '#d9d9d9'),
      _PaletteColor('黒、文字1、白を80%', '#cccccc'),
      _PaletteColor('薄い灰色、白を60%', '#e7e6e6'),
      _PaletteColor('濃い青、白を60%', '#adb9ca'),
      _PaletteColor('青、白を60%', '#b4c6e7'),
      _PaletteColor('オレンジ、白を60%', '#f8cbad'),
      _PaletteColor('灰色、白を60%', '#dbdbdb'),
      _PaletteColor('黄、白を60%', '#ffe699'),
      _PaletteColor('薄い青、白を60%', '#bdd7ee'),
      _PaletteColor('緑、白を60%', '#c6e0b4'),
    ],
    [
      _PaletteColor('白、背景1、黒を25%', '#bfbfbf'),
      _PaletteColor('黒、文字1、白を65%', '#a6a6a6'),
      _PaletteColor('薄い灰色、黒を10%', '#d0cece'),
      _PaletteColor('濃い青、白を40%', '#8497b0'),
      _PaletteColor('青、白を40%', '#8eaadb'),
      _PaletteColor('オレンジ、白を40%', '#f4b183'),
      _PaletteColor('灰色、白を40%', '#c9c9c9'),
      _PaletteColor('黄、白を40%', '#ffd966'),
      _PaletteColor('薄い青、白を40%', '#9dc3e6'),
      _PaletteColor('緑、白を40%', '#a9d18e'),
    ],
    [
      _PaletteColor('白、背景1、黒を35%', '#a6a6a6'),
      _PaletteColor('黒、文字1、白を50%', '#7f7f7f'),
      _PaletteColor('薄い灰色、黒を25%', '#aeaaaa'),
      _PaletteColor('濃い青、黒を25%', '#333f50'),
      _PaletteColor('青、黒を25%', '#2f5597'),
      _PaletteColor('オレンジ、黒を25%', '#c65911'),
      _PaletteColor('灰色、黒を25%', '#7b7b7b'),
      _PaletteColor('黄、黒を25%', '#bf9000'),
      _PaletteColor('薄い青、黒を25%', '#2e75b6'),
      _PaletteColor('緑、黒を25%', '#548235'),
    ],
    [
      _PaletteColor('白、背景1、黒を50%', '#7f7f7f'),
      _PaletteColor('黒、文字1、白を35%', '#595959'),
      _PaletteColor('薄い灰色、黒を50%', '#767171'),
      _PaletteColor('濃い青、黒を50%', '#222a35'),
      _PaletteColor('青、黒を50%', '#203864'),
      _PaletteColor('オレンジ、黒を50%', '#833c0c'),
      _PaletteColor('灰色、黒を50%', '#525252'),
      _PaletteColor('黄、黒を50%', '#7f6000'),
      _PaletteColor('薄い青、黒を50%', '#1f4e78'),
      _PaletteColor('緑、黒を50%', '#375623'),
    ],
  ];
  static const _standardColors = <_PaletteColor>[
    _PaletteColor('濃い赤', '#c00000'),
    _PaletteColor('赤', '#ff0000'),
    _PaletteColor('オレンジ', '#ffc000'),
    _PaletteColor('黄', '#ffff00'),
    _PaletteColor('黄緑', '#92d050'),
    _PaletteColor('緑', '#00b050'),
    _PaletteColor('青緑', '#00b0f0'),
    _PaletteColor('青', '#0070c0'),
    _PaletteColor('濃い青', '#002060'),
    _PaletteColor('紫', '#7030a0'),
  ];

  late final TextEditingController _sizeController;
  late final FocusNode _sizeFocusNode;
  Color _textColor = Colors.red;
  Color _backgroundColor = const Color(0xfffff200);

  @override
  void initState() {
    super.initState();
    _sizeController = TextEditingController(
      text: _number(widget.defaultFontSize),
    );
    _sizeFocusNode = FocusNode(debugLabel: '文字サイズ入力欄')
      ..addListener(() {
        if (!_sizeFocusNode.hasFocus) _applySize();
      });
  }

  @override
  void didUpdateWidget(covariant ExcelFormatControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.defaultFontSize != widget.defaultFontSize) {
      _sizeController.text = _number(widget.defaultFontSize);
    }
  }

  @override
  void dispose() {
    _sizeFocusNode.dispose();
    _sizeController.dispose();
    super.dispose();
  }

  String _number(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(1);

  void _applySize([double? selected]) {
    final value = selected ?? double.tryParse(_sizeController.text.trim());
    if (value == null || value < 1 || value > 400) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文字サイズは1から400の数字で入力してください。')),
        );
      }
      return;
    }
    _sizeController.text = _number(value);
    widget.controller.formatSelection(SizeAttribute(_number(value)));
    widget.editorFocusNode.requestFocus();
  }

  void _applyDefaultSize() {
    _sizeController.text = _number(widget.defaultFontSize);
    widget.controller.formatSelection(Attribute.clone(Attribute.size, null));
    widget.editorFocusNode.requestFocus();
  }

  Future<void> _chooseColor(bool background) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => Dialog(
        alignment: MediaQuery.sizeOf(context).width >= 700
            ? Alignment.topLeft
            : Alignment.center,
        insetPadding: MediaQuery.sizeOf(context).width >= 700
            ? const EdgeInsets.only(left: 255, top: 82, right: 24, bottom: 24)
            : const EdgeInsets.all(20),
        child: SizedBox(
          width: 300,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  background ? '背景の色' : '文字の色',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                InkWell(
                  onTap: () => Navigator.pop(context, '__clear__'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Row(
                      children: [
                        const Icon(Icons.format_color_reset, size: 20),
                        const SizedBox(width: 9),
                        Text(background ? '塗りつぶしなし' : '自動'),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 10),
                const Text(
                  'テーマの色',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 7),
                for (final row in _themeColors)
                  Row(
                    children: [
                      for (final color in row) _colorCell(context, color),
                    ],
                  ),
                const SizedBox(height: 10),
                const Text(
                  '標準の色',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 7),
                Row(
                  children: [
                    for (final color in _standardColors)
                      _colorCell(context, color),
                  ],
                ),
                const Divider(height: 18),
                TextButton.icon(
                  onPressed: () async {
                    final custom = await _customColor(context);
                    if (context.mounted && custom != null) {
                      Navigator.pop(context, custom);
                    }
                  },
                  icon: const Icon(Icons.palette_outlined),
                  label: const Text('その他の色…'),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('キャンセル'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final value = selected == '__clear__' ? null : selected;
    widget.controller.formatSelection(
      background ? BackgroundAttribute(value) : ColorAttribute(value),
    );
    if (value != null) {
      setState(() {
        if (background) {
          _backgroundColor = _parseColor(value);
        } else {
          _textColor = _parseColor(value);
        }
      });
    }
    widget.editorFocusNode.requestFocus();
  }

  Widget _colorCell(BuildContext context, _PaletteColor color) => Tooltip(
    message: color.name,
    child: InkWell(
      onTap: () => Navigator.pop(context, color.hex),
      child: Container(
        width: 25,
        height: 24,
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: _parseColor(color.hex),
          border: Border.all(color: Colors.black26),
        ),
      ),
    ),
  );

  Future<String?> _customColor(BuildContext parentContext) async {
    final input = TextEditingController(text: '#4472c4');
    final result = await showDialog<String>(
      context: parentContext,
      builder: (context) => AlertDialog(
        title: const Text('その他の色'),
        content: TextField(
          controller: input,
          autofocus: true,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F#]')),
          ],
          decoration: const InputDecoration(
            labelText: '色コード',
            hintText: '#4472c4',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () {
              var value = input.text.trim();
              if (!value.startsWith('#')) value = '#$value';
              if (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
                Navigator.pop(context, value.toLowerCase());
              }
            },
            child: const Text('適用'),
          ),
        ],
      ),
    );
    input.dispose();
    return result;
  }

  Color _parseColor(String hex) =>
      Color(int.parse('ff${hex.substring(1)}', radix: 16));

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 42,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 80,
          height: 34,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Row(
            children: [
              Expanded(
                child: Tooltip(
                  message: '文字サイズ',
                  child: TextField(
                    key: const ValueKey('font-size-field'),
                    controller: _sizeController,
                    focusNode: _sizeFocusNode,
                    textAlign: TextAlign.center,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                    ),
                    onSubmitted: (_) => _applySize(),
                  ),
                ),
              ),
              PopupMenuButton<double>(
                tooltip: '文字サイズの一覧',
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.arrow_drop_down, size: 18),
                onSelected: (value) =>
                    value == 0 ? _applyDefaultSize() : _applySize(value),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 0,
                    child: Row(
                      children: [
                        const Icon(Icons.format_size, size: 21),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('標準文字サイズを適用'),
                            Text(
                              '現在の標準：${_number(widget.defaultFontSize)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  for (final size in _fontSizes)
                    PopupMenuItem(value: size, child: Text(_number(size))),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        _ExcelColorButton(
          tooltip: '背景の色',
          icon: Icons.format_color_fill,
          color: _backgroundColor,
          onApply: () {
            widget.controller.formatSelection(
              BackgroundAttribute(
                '#${_backgroundColor.toARGB32().toRadixString(16).substring(2)}',
              ),
            );
            widget.editorFocusNode.requestFocus();
          },
          onChoose: () => _chooseColor(true),
        ),
        _ExcelColorButton(
          tooltip: '文字の色',
          icon: Icons.format_color_text,
          color: _textColor,
          onApply: () {
            widget.controller.formatSelection(
              ColorAttribute(
                '#${_textColor.toARGB32().toRadixString(16).substring(2)}',
              ),
            );
            widget.editorFocusNode.requestFocus();
          },
          onChoose: () => _chooseColor(false),
        ),
      ],
    ),
  );
}

class _ExcelColorButton extends StatelessWidget {
  const _ExcelColorButton({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onApply,
    required this.onChoose,
  });
  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onApply;
  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) => Container(
    height: 38,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(3),
      border: Border.all(color: Colors.transparent),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: '現在の$tooltipを適用',
          child: InkWell(
            onTap: onApply,
            child: SizedBox(
              width: 34,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(icon, size: 22),
                  Positioned(
                    left: 6,
                    right: 6,
                    bottom: 3,
                    child: Container(height: 4, color: color),
                  ),
                ],
              ),
            ),
          ),
        ),
        Tooltip(
          message: tooltip,
          child: InkWell(
            onTap: onChoose,
            child: const SizedBox(
              width: 18,
              height: 38,
              child: Icon(Icons.arrow_drop_down, size: 17),
            ),
          ),
        ),
      ],
    ),
  );
}

class _PaletteColor {
  const _PaletteColor(this.name, this.hex);
  final String name;
  final String hex;
}

