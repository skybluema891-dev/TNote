import 'package:flutter/services.dart';

class EditorPosition {
  const EditorPosition({
    required this.base,
    required this.extent,
    required this.scroll,
  });
  final int base;
  final int extent;
  final double scroll;

  TextSelection selectionFor(int end) => TextSelection(
    baseOffset: base.clamp(0, end),
    extentOffset: extent.clamp(0, end),
  );

  Map<String, Object> toJson() => {
    'base': base,
    'extent': extent,
    'scroll': scroll,
  };

  factory EditorPosition.fromJson(Map<String, dynamic> json) {
    final offset = (json['scroll'] as num).toDouble();
    if (!offset.isFinite || offset < 0) throw const FormatException('不正な表示位置');
    return EditorPosition(
      base: json['base'] as int,
      extent: json['extent'] as int,
      scroll: offset,
    );
  }
}
