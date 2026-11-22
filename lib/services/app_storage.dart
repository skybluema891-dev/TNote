import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

SharedPreferencesWindowsOptions? _windowsOptions;
File? managedWindowsSetup;

Future<Directory> configureAppStorage() async {
  if (Platform.isWindows) {
    final executable = File(Platform.resolvedExecutable);
    final directory = await readPortableStorage(executable.parent);
    if (directory != null) {
      // The Windows implementation joins this filename to its default storage
      // directory. An absolute filename resolves to the configured directory.
      _windowsOptions = SharedPreferencesWindowsOptions(
        fileName: p.join(directory.path, 'shared_preferences'),
      );
      return directory;
    }
  }
  return getApplicationSupportDirectory();
}

SharedPreferencesAsync appPreferences() {
  final options = _windowsOptions;
  return options == null
      ? SharedPreferencesAsync()
      : SharedPreferencesAsync(options: options);
}

Future<Directory?> readPortableStorage(Directory installation) async {
  final file = File(p.join(installation.path, 'runtime.json'));
  if (!await file.exists()) return null;

  final config = jsonDecode(await file.readAsString());
  if (config is! Map ||
      config['id'] != 'tnote' ||
      config['data_mode'] != 'portable') {
    throw const FormatException('TNoteの保存先設定を読み込めません。');
  }
  final relative = config['data_relative'];
  if (relative is! String ||
      relative.trim().isEmpty ||
      p.isAbsolute(relative) ||
      p.rootPrefix(relative).isNotEmpty ||
      relative.contains(':')) {
    throw const FormatException('TNoteの保存先設定には相対パスが必要です。');
  }
  final directory = Directory(
    p.normalize(p.join(installation.absolute.path, relative)),
  );
  if (!await directory.exists()) {
    throw const FileSystemException('TNoteのユーザーデータ保存先が見つかりません。');
  }
  final setup = config['setup_relative'];
  if (setup is String) {
    final expected = p.join(
      installation.absolute.parent.path,
      'distribution',
      'TNoteSetup.exe',
    );
    if (p.equals(
      p.normalize(p.join(installation.absolute.path, setup)),
      expected,
    )) {
      managedWindowsSetup = File(expected);
    }
  }
  return directory;
}
