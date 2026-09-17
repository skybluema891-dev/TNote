import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:jis0208/jis0208.dart';
import 'package:path/path.dart' as p;

class DecodedTextFile {
  const DecodedTextFile({
    required this.text,
    required this.encoding,
    required this.fingerprint,
  });

  final String text;
  final String encoding;
  final String fingerprint;
}

class TextFileService {
  static const supportedExtensions = {'txt', 'md', 'markdown', 'log'};

  static bool supportsPath(String path) {
    final extension = p.extension(path).toLowerCase().replaceFirst('.', '');
    return supportedExtensions.contains(extension);
  }

  Future<DecodedTextFile> read(String path) async {
    final bytes = await File(path).readAsBytes();
    final fingerprint = sha256.convert(bytes).toString();
    if (bytes.isEmpty) {
      return DecodedTextFile(
        text: '',
        encoding: 'utf-8',
        fingerprint: fingerprint,
      );
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf) {
      return DecodedTextFile(
        text: utf8.decode(bytes.sublist(3), allowMalformed: false),
        encoding: 'utf-8-bom',
        fingerprint: fingerprint,
      );
    }
    try {
      return DecodedTextFile(
        text: utf8.decode(bytes, allowMalformed: false),
        encoding: 'utf-8',
        fingerprint: fingerprint,
      );
    } on FormatException {
      try {
        return DecodedTextFile(
          text: Windows31JDecoder().convert(bytes),
          encoding: 'windows-31j',
          fingerprint: fingerprint,
        );
      } on FormatException {
        throw const FormatException(
          '文字コードを判定できません。UTF-8またはShift-JIS（CP932）のファイルを選んでください。',
        );
      }
    }
  }

  Future<String> write(
    String path,
    String text, {
    String encoding = 'utf-8',
  }) async {
    final bytes = switch (encoding) {
      'windows-31j' => Windows31JEncoder().convert(text),
      'utf-8-bom' => Uint8List.fromList([
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode(text),
      ]),
      _ => Uint8List.fromList(utf8.encode(text)),
    };
    final destination = File(path);
    await destination.parent.create(recursive: true);
    final temporary = File(
      p.join(
        destination.parent.path,
        '.${p.basename(path)}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    await temporary.writeAsBytes(bytes, flush: true);
    File? backup;
    try {
      if (await destination.exists()) {
        backup = File('$path.tnote-writing-backup');
        if (await backup.exists()) await backup.delete();
        await destination.rename(backup.path);
      }
      await temporary.rename(path);
      if (backup != null && await backup.exists()) await backup.delete();
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      if (backup != null &&
          await backup.exists() &&
          !await destination.exists()) {
        await backup.rename(path);
      }
      rethrow;
    }
    return sha256.convert(bytes).toString();
  }
}
