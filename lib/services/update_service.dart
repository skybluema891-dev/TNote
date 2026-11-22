// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_storage.dart';

class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.build,
    required this.windowsUrl,
    required this.macosUrl,
    required this.releaseUrl,
    required this.releaseNotes,
    required this.minimumSchemaVersion,
    this.windowsSha256,
    this.windowsSize,
    this.windowsArchitecture,
    this.windowsBackground = false,
  });

  final String version;
  final int build;
  final String windowsUrl;
  final String macosUrl;
  final String releaseUrl;
  final List<String> releaseNotes;
  final int minimumSchemaVersion;
  final String? windowsSha256;
  final int? windowsSize;
  final String? windowsArchitecture;
  final bool windowsBackground;

  factory ReleaseInfo.fromJson(Map<String, dynamic> json) => ReleaseInfo(
    version: json['version'] as String,
    build: (json['build'] as num).toInt(),
    windowsUrl: json['windows_url'] as String,
    macosUrl: json['macos_url'] as String,
    releaseUrl: json['release_url'] as String,
    releaseNotes: (json['release_notes'] as List? ?? const [])
        .map((item) => item.toString())
        .toList(),
    minimumSchemaVersion: (json['minimum_schema_version'] as num? ?? 1).toInt(),
    windowsSha256: json['windows_sha256'] as String?,
    windowsSize: json['windows_size'] as int?,
    windowsArchitecture: json['windows_architecture'] as String?,
    windowsBackground: json['windows_background'] == true,
  );
}

class ReadyWindowsUpdate {
  const ReadyWindowsUpdate(this.release, this.installer);
  final ReleaseInfo release;
  final File installer;
}

abstract class UpdateStateStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
}

class SharedPreferencesUpdateStateStore implements UpdateStateStore {
  SharedPreferencesUpdateStateStore([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? appPreferences();
  final SharedPreferencesAsync _preferences;
  @override
  Future<String?> getString(String key) => _preferences.getString(key);
  @override
  Future<void> setString(String key, String value) =>
      _preferences.setString(key, value);
}

class UpdateService {
  // Named public constructor parameters are kept for straightforward test injection.
  UpdateService({http.Client? client, UpdateStateStore? stateStore})
    : _client = client,
      _stateStore = stateStore;

  static const releaseInfoUrl = String.fromEnvironment(
    'TNOTE_RELEASE_INFO_URL',
    defaultValue: 'https://github.com/skybluema891-dev/TNote/releases/latest/download/release-info.json',
  );
  static const _skippedVersionKey = 'updateSkippedVersion';
  static const _repository = 'skybluema891-dev/TNote';
  static final _stableVersion = RegExp(r'^\d+\.\d+\.\d+$');
  static final _sha256 = RegExp(r'^[0-9a-f]{64}$');

  http.Client? _client;
  http.Client get _http => _client ??= http.Client();
  UpdateStateStore? _stateStore;
  UpdateStateStore get _state =>
      _stateStore ??= SharedPreferencesUpdateStateStore();

  Future<ReleaseInfo?> check({
    required String currentVersion,
    required int currentBuild,
    bool manual = false,
    DateTime? now,
  }) async {
    try {
      final info = await latestPublicRelease();
      if (info == null) return null;
      final skipped = await _state.getString(_skippedVersionKey);
      if (!manual && skipped == info.version) return null;
      return isNewer(info.version, info.build, currentVersion, currentBuild)
          ? info
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> skip(String version) =>
      _state.setString(_skippedVersionKey, version);

  Future<ReleaseInfo?> latestPublicRelease() async {
    final source = Uri.parse(releaseInfoUrl);
    final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    // The latest-release redirect can be cached even after GitHub publishes
    // a new asset. Revalidate that redirect for each check.
    final uri = source.replace(
      queryParameters: {...source.queryParameters, 'tnote_check': '$timestamp'},
    );
    final response = await _http
        .get(uri, headers: const {'Cache-Control': 'no-cache'})
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return null;
    final info = ReleaseInfo.fromJson(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
    );
    return _stableVersion.hasMatch(info.version) && info.build > 0
        ? info
        : null;
  }

  static bool get supportsWindowsInstaller =>
      Platform.isWindows && Abi.current() == Abi.windowsX64;

  static bool validWindowsRelease(ReleaseInfo info) {
    if (!_stableVersion.hasMatch(info.version) ||
        info.build <= 0 ||
        info.minimumSchemaVersion > 2 ||
        info.windowsArchitecture != 'x64' ||
        info.windowsBackground != true ||
        !_sha256.hasMatch(info.windowsSha256 ?? '') ||
        (info.windowsSize ?? 0) <= 0 ||
        info.windowsSize! > 200 * 1024 * 1024) {
      return false;
    }
    final version = info.version;
    return info.windowsUrl ==
        'https://github.com/$_repository/releases/download/v$version/TNote-Setup-$version.exe';
  }

  Future<ReadyWindowsUpdate?> prepareWindowsUpdate({
    required String version,
    required int build,
    required File destination,
    required bool keepCurrentSetup,
  }) async {
    final info = await latestPublicRelease();
    if (info == null || !validWindowsRelease(info)) return null;
    final newer = isNewer(info.version, info.build, version, build);
    if (!newer &&
        !(keepCurrentSetup && info.version == version && info.build == build)) {
      return null;
    }
    await downloadWindowsInstaller(info, destination);
    return newer ? ReadyWindowsUpdate(info, destination) : null;
  }

  Future<http.StreamedResponse> _requestWindowsAsset(Uri uri) async {
    final original = uri;
    for (var redirect = 0; redirect < 5; redirect++) {
      if (uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          uri.port != 443 ||
          (uri != original &&
              uri.host != 'release-assets.githubusercontent.com' &&
              uri.host != 'objects.githubusercontent.com')) {
        throw const FormatException('更新ファイルの配布元を確認できません。');
      }
      final request = http.Request('GET', uri)..followRedirects = false;
      final response = await _http
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) return response;
      if (![301, 302, 303, 307, 308].contains(response.statusCode)) break;
      final location = response.headers['location'];
      await response.stream.drain<void>().timeout(const Duration(seconds: 10));
      if (location == null) break;
      uri = uri.resolve(location);
    }
    throw const HttpException('更新ファイルをダウンロードできませんでした。');
  }

  Future<bool> verifyInstaller(ReleaseInfo info, File file) async =>
      validWindowsRelease(info) &&
      await file.exists() &&
      await file.length() == info.windowsSize &&
      (await sha256.bind(file.openRead()).first).toString() ==
          info.windowsSha256;

  Future<void> downloadWindowsInstaller(
    ReleaseInfo info,
    File destination,
  ) async {
    if (!validWindowsRelease(info)) {
      throw const FormatException('更新情報を検証できませんでした。');
    }
    if (await verifyInstaller(info, destination)) return;
    final directory = await destination.parent.create(recursive: true);
    final staging = await directory.createTemp('.tnote-download-');
    final candidate = File(p.join(staging.path, 'TNoteSetup.part'));
    try {
      final response = await _requestWindowsAsset(Uri.parse(info.windowsUrl));
      final output = await candidate.open(mode: FileMode.write);
      var bytes = 0;
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          bytes += chunk.length;
          if (bytes > info.windowsSize!) {
            throw const FormatException('更新ファイルのサイズが正しくありません。');
          }
          await output.writeFrom(chunk);
        }
        await output.flush();
      } finally {
        await output.close();
      }
      if (!await verifyInstaller(info, candidate)) {
        throw const FormatException('更新ファイルの検証に失敗しました。');
      }
      // Use a same-volume rename only after verification, leaving the prior
      // setup usable through interrupted downloads and validation failures.
      await candidate.rename(destination.path);
    } finally {
      if (await candidate.exists()) await candidate.delete();
      await staging.delete();
    }
  }

  static bool isNewer(
    String candidateVersion,
    int candidateBuild,
    String currentVersion,
    int currentBuild,
  ) {
    final candidate = _parts(candidateVersion);
    final current = _parts(currentVersion);
    for (var i = 0; i < 3; i++) {
      if (candidate[i] != current[i]) return candidate[i] > current[i];
    }
    return candidateBuild > currentBuild;
  }

  static List<int> _parts(String version) {
    final values = version
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
    return List<int>.generate(
      3,
      (index) => index < values.length ? values[index] : 0,
    );
  }

  void close() => _client?.close();
}
