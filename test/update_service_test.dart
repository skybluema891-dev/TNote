import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tnote/services/update_service.dart';

class MemoryUpdateStateStore implements UpdateStateStore {
  final Map<String, String> values = {};
  @override
  Future<String?> getString(String key) async => values[key];
  @override
  Future<void> setString(String key, String value) async => values[key] = value;
}

String releaseJson({String version = '1.3.0', int build = 8}) => jsonEncode({
  'version': version,
  'build': build,
  'windows_url': 'https://example.test/TNote-Setup-1.3.3.exe',
  'macos_url': 'https://example.test/TNote-1.3.3.dmg',
  'release_url': 'https://example.test/release',
  'release_notes': ['貼り付けを修正'],
  'minimum_schema_version': 2,
});

void main() {
  test('リリース情報からOS別のインストーラーURLを解析する', () {
    final info = ReleaseInfo.fromJson(
      jsonDecode(releaseJson(version: '1.3.3', build: 11))
          as Map<String, dynamic>,
    );
    expect(info.version, '1.3.3');
    expect(info.build, 11);
    expect(info.windowsUrl, endsWith('TNote-Setup-1.3.3.exe'));
    expect(info.macosUrl, endsWith('TNote-1.3.3.dmg'));
  });

  test('新しいバージョンだけを通知する', () {
    expect(UpdateService.isNewer('1.3.0', 8, '1.2.0', 7), isTrue);
    expect(UpdateService.isNewer('1.2.0', 7, '1.2.0', 7), isFalse);
    expect(UpdateService.isNewer('1.2.0', 8, '1.2.0', 7), isTrue);
    expect(UpdateService.isNewer('1.1.9', 99, '1.2.0', 7), isFalse);
  });

  test('起動するたびに最新版を確認し、手動確認も実行する', () async {
    var requests = 0;
    final store = MemoryUpdateStateStore();
    final service = UpdateService(
      stateStore: store,
      client: MockClient((_) async {
        requests++;
        return http.Response.bytes(utf8.encode(releaseJson()), 200);
      }),
    );
    final first = await service.check(
      currentVersion: '1.2.0',
      currentBuild: 7,
      now: DateTime.utc(2026, 9, 13),
    );
    expect(first?.version, '1.3.0');
    expect(requests, 1);
    expect(
      await service.check(
        currentVersion: '1.2.0',
        currentBuild: 7,
        now: DateTime.utc(2026, 9, 13, 1),
      ),
      isNotNull,
    );
    expect(requests, 2);
    expect(
      await service.check(
        currentVersion: '1.2.0',
        currentBuild: 7,
        manual: true,
        now: DateTime.utc(2026, 9, 13, 1),
      ),
      isNotNull,
    );
    expect(requests, 3);
    service.close();
  });

  test('スキップした版は自動通知せず、手動確認では表示する', () async {
    final store = MemoryUpdateStateStore();
    final service = UpdateService(
      stateStore: store,
      client: MockClient(
        (_) async => http.Response.bytes(utf8.encode(releaseJson()), 200),
      ),
    );
    await service.skip('1.3.0');
    expect(
      await service.check(
        currentVersion: '1.2.0',
        currentBuild: 7,
        now: DateTime.utc(2026, 9, 13),
      ),
      isNull,
    );
    expect(
      await service.check(
        currentVersion: '1.2.0',
        currentBuild: 7,
        manual: true,
        now: DateTime.utc(2026, 9, 13, 1),
      ),
      isNotNull,
    );
    service.close();
  });

  test('ネット接続に失敗しても例外にせず通常起動を続ける', () async {
    final service = UpdateService(
      stateStore: MemoryUpdateStateStore(),
      client: MockClient((_) async => throw http.ClientException('offline')),
    );
    expect(
      await service.check(
        currentVersion: '1.2.0',
        currentBuild: 7,
        now: DateTime.utc(2026, 9, 13),
      ),
      isNull,
    );
    service.close();
  });
}
