import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';

class SettingsService {
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  Future<AppSettings> load() async {
    final settings = AppSettings();
    final themeName = await _prefs.getString('themeMode') ?? 'system';
    settings.update(
      autosave: await _prefs.getBool('autosave') ?? true,
      autosaveSeconds: await _prefs.getInt('autosaveSeconds') ?? 2,
      backupGenerations: await _prefs.getInt('backupGenerations') ?? 10,
      recentLimit: await _prefs.getInt('recentLimit') ?? 20,
      defaultFontSize: await _prefs.getDouble('defaultFontSize') ?? 16,
      themeMode: ThemeMode.values.firstWhere(
        (value) => value.name == themeName,
        orElse: () => ThemeMode.system,
      ),
    );
    return settings;
  }

  Future<void> save(AppSettings settings) async {
    await Future.wait([
      _prefs.setBool('autosave', settings.autosave),
      _prefs.setInt('autosaveSeconds', settings.autosaveSeconds),
      _prefs.setInt('backupGenerations', settings.backupGenerations),
      _prefs.setInt('recentLimit', settings.recentLimit),
      _prefs.setDouble('defaultFontSize', settings.defaultFontSize),
      _prefs.setString('themeMode', settings.themeMode.name),
    ]);
  }
}
