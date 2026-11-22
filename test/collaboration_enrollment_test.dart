import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tnote/services/collaboration_keys.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('移行情報は対象のメモと一致するときだけ使用する', () async {
    final folder = await Directory.systemTemp.createTemp('tnote-receipt-');
    final receipt = File('${folder.path}/sample.tnote-join');
    const channel = MethodChannel('tnote/windows_installation');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final key = Uint8List.fromList(List.filled(32, 17));
    final room = sha256.convert([
      ...utf8.encode('TNote room 1'),
      ...key,
    ]).toString();
    var reads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'openMigrationEnrollment');
      expect((call.arguments as List).first, room);
      reads++;
      return key.asUnmodifiableView();
    });
    try {
      await receipt.writeAsString(
        jsonEncode({
          'format': 'TNote migration key v1',
          'room': room,
          'protected': 'AQID',
        }),
      );
      final vault = const CollaborationKeys();
      expect(await vault.openEnrollment(receipt, room), base64UrlEncode(key));
      await expectLater(
        vault.openEnrollment(receipt, '0' * 64),
        throwsFormatException,
      );
      expect(reads, 1);
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
      if (await receipt.exists()) await receipt.delete();
      if (await folder.list().isEmpty) await folder.delete();
    }
  }, skip: !Platform.isWindows);
}
