import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
  test('検証済みの内容だけを保存用セットアップへ反映する', () async {
    final directory = await Directory.systemTemp.createTemp(
      'tnote-update-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final target = File.fromUri(directory.uri.resolve('TNoteSetup.exe'));
    await target.writeAsString('existing');
    final bytes = utf8.encode('verified installer');
    const url =
        'https://github.com/skybluema891-dev/TNote/releases/download/v1.4.6/TNote-Setup-1.4.6.exe';
    final release = ReleaseInfo(
      version: '1.4.6',
      build: 19,
      windowsUrl: url,
      macosUrl: '',
      releaseUrl: '',
      releaseNotes: const [],
      minimumSchemaVersion: 2,
      windowsSize: bytes.length,
      windowsSha256: sha256.convert(bytes).toString(),
      windowsArchitecture: 'x64',
      windowsBackground: true,
    );
    String? redirect;
    var payload = List<int>.filled(bytes.length, 0);
    final service = UpdateService(
      client: MockClient((request) async {
        if (redirect != null) {
          return http.Response('', 302, headers: {'location': redirect});
        }
        return http.Response.bytes(payload, 200);
      }),
    );
    addTearDown(service.close);
    await expectLater(
      service.downloadWindowsInstaller(release, target),
      throwsFormatException,
    );
    expect(await target.readAsString(), 'existing');
    redirect = 'https://downloads.example.test/replacement.exe';
    await expectLater(
      service.downloadWindowsInstaller(release, target),
      throwsFormatException,
    );
    expect(await target.readAsString(), 'existing');
    redirect = null;
    payload = bytes;
    await service.downloadWindowsInstaller(release, target);
    expect(await target.readAsBytes(), bytes);
    expect(await directory.list().length, 1);
  });

  test('同じ版でも管理用セットアップを修復し、旧版への巻き戻しを避ける', () async {
    final directory = await Directory.systemTemp.createTemp('tnote-managed-');
    addTearDown(() => directory.delete(recursive: true));
    final setup = File.fromUri(directory.uri.resolve('TNoteSetup.exe'));
    final bytes = utf8.encode('signed release payload');
    final latest = {
      ...jsonDecode(releaseJson(version: '1.5.1', build: 22))
          as Map<String, dynamic>,
      'windows_url': 'https://github.com/skybluema891-dev/TNote/releases/download/v1.5.1/TNote-Setup-1.5.1.exe',
      'windows_architecture': 'x64',
      'windows_size': bytes.length,
      'windows_sha256': sha256.convert(bytes).toString(),
      'windows_background': true,
    };
    var downloads = 0;
    final service = UpdateService(
      client: MockClient((request) async {
        if (request.url.path.endsWith('.json')) {
          return http.Response.bytes(utf8.encode(jsonEncode(latest)), 200);
        }
        downloads++;
        return http.Response.bytes(bytes, 200);
      }),
    );
    addTearDown(service.close);
    Future<ReadyWindowsUpdate?> check(String version, int build) =>
        service.prepareWindowsUpdate(
          version: version,
          build: build,
          destination: setup,
          keepCurrentSetup: true,
        );
    await setup.writeAsString('old setup');
    expect(await check('1.6.0', 23), isNull);
    expect(await setup.readAsString(), 'old setup');
    expect(await check('1.5.1', 22), isNull);
    expect(await setup.readAsBytes(), bytes);
    expect((await check('1.5.0', 21))?.release.build, 22);
    expect(downloads, 1);
  });

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
      client: MockClient((request) async {
        expect(request.url.queryParameters['tnote_check'], isNotEmpty);
        expect(request.headers['cache-control'], 'no-cache');
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
