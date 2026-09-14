// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

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
  });

  final String version;
  final int build;
  final String windowsUrl;
  final String macosUrl;
  final String releaseUrl;
  final List<String> releaseNotes;
  final int minimumSchemaVersion;
  final String? windowsSha256;

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
  );
}

abstract class UpdateStateStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
}

class SharedPreferencesUpdateStateStore implements UpdateStateStore {
  SharedPreferencesUpdateStateStore([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? SharedPreferencesAsync();
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
      final response = await _http
          .get(Uri.parse(releaseInfoUrl))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final info = ReleaseInfo.fromJson(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
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

  Future<File> downloadWindowsInstaller(ReleaseInfo info) async {
    final response = await _http
        .get(Uri.parse(info.windowsUrl))
        .timeout(const Duration(minutes: 3));
    if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
      throw const HttpException('更新ファイルをダウンロードできませんでした。');
    }
    final expected = info.windowsSha256?.trim().toLowerCase();
    if (expected != null && expected.isNotEmpty) {
      final actual = sha256.convert(response.bodyBytes).toString();
      if (actual != expected) {
        throw const FormatException('更新ファイルの検証に失敗しました。');
      }
    }
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}TNoteSetup-${info.version}.exe',
    );
    await file.writeAsBytes(response.bodyBytes, flush: true);
    return file;
  }

  Future<void> openMacDownload(ReleaseInfo info) async {
    final uri = Uri.parse(
      info.macosUrl.isEmpty ? info.releaseUrl : info.macosUrl,
    );
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw const OSError('更新ページを開けませんでした。');
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

