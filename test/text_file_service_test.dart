import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jis0208/jis0208.dart';
import 'package:path/path.dart' as p;
import 'package:tnote/services/text_file_service.dart';

void main() {
  late Directory directory;
  late TextFileService service;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tnote-text-test-');
    service = TextFileService();
  });

  tearDown(() => directory.delete(recursive: true));

  test('UTF-8、BOM付きUTF-8、Windows-31Jを自動判定する', () async {
    final utf8File = File(p.join(directory.path, 'utf8.txt'));
    await utf8File.writeAsString('日本語😀');
    final utf8Result = await service.read(utf8File.path);
    expect(utf8Result.text, '日本語😀');
    expect(utf8Result.encoding, 'utf-8');

    final bomFile = File(p.join(directory.path, 'bom.md'));
    await bomFile.writeAsBytes([0xef, 0xbb, 0xbf, ...utf8.encode('見出し')]);
    final bomResult = await service.read(bomFile.path);
    expect(bomResult.text, '見出し');
    expect(bomResult.encoding, 'utf-8-bom');

    final sjisFile = File(p.join(directory.path, 'sjis.log'));
    await sjisFile.writeAsBytes(Windows31JEncoder().convert('表計算①'));
    final sjisResult = await service.read(sjisFile.path);
    expect(sjisResult.text, '表計算①');
    expect(sjisResult.encoding, 'windows-31j');
  });

  test('元の文字コードを保って安全に上書きする', () async {
    final file = File(p.join(directory.path, '仕事.txt'));
    await file.writeAsBytes(Windows31JEncoder().convert('変更前'));
    await service.write(file.path, '変更後', encoding: 'windows-31j');
    expect(Windows31JDecoder().convert(await file.readAsBytes()), '変更後');
    expect(await File('${file.path}.tnote-writing-backup').exists(), isFalse);
  });
}
