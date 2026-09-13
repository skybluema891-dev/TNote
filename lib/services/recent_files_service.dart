import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

class RecentFile {
  const RecentFile({
    required this.path,
    required this.lastOpened,
    this.favorite = false,
  });
  final String path;
  final DateTime lastOpened;
  final bool favorite;
  Map<String, dynamic> toJson() => {
    'path': path,
    'lastOpened': lastOpened.toUtc().toIso8601String(),
    'favorite': favorite,
  };
  factory RecentFile.fromJson(Map<String, dynamic> json) => RecentFile(
    path: json['path'] as String,
    lastOpened: DateTime.parse(json['lastOpened'] as String),
    favorite: json['favorite'] as bool? ?? false,
  );
}

class RecentFilesService {
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();
  List<RecentFile> items = [];

  Future<void> load({int limit = 20}) async {
    final raw = await _prefs.getString('recentFilesV1');
    if (raw == null) return;
    try {
      items =
          (jsonDecode(raw) as List)
              .map(
                (item) =>
                    RecentFile.fromJson(Map<String, dynamic>.from(item as Map)),
              )
              .where((item) => File(item.path).existsSync())
              .toList()
            ..sort((a, b) => b.lastOpened.compareTo(a.lastOpened));
      await _trimAndSave(limit);
    } catch (_) {
      items = [];
    }
  }

  Future<void> touch(String path, {int limit = 20}) async {
    final existing = items.where((item) => _same(item.path, path)).firstOrNull;
    items.removeWhere((item) => _same(item.path, path));
    items.insert(
      0,
      RecentFile(
        path: path,
        lastOpened: DateTime.now(),
        favorite: existing?.favorite ?? false,
      ),
    );
    await _trimAndSave(limit);
  }

  Future<void> toggleFavorite(String path, {int limit = 20}) async {
    final index = items.indexWhere((item) => _same(item.path, path));
    if (index < 0) return;
    final item = items[index];
    items[index] = RecentFile(
      path: item.path,
      lastOpened: item.lastOpened,
      favorite: !item.favorite,
    );
    await _trimAndSave(limit);
  }

  Future<void> _trimAndSave(int limit) async {
    final favorites = items.where((item) => item.favorite).toList();
    final regular = items.where((item) => !item.favorite).take(limit).toList();
    items = [...favorites, ...regular];
    await _prefs.setString(
      'recentFilesV1',
      jsonEncode(items.map((item) => item.toJson()).toList()),
    );
  }

  bool _same(String a, String b) =>
      Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
}
