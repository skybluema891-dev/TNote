import 'package:flutter/material.dart';

class AppSettings extends ChangeNotifier {
  bool autosave = true;
  int autosaveSeconds = 2;
  int backupGenerations = 10;
  int recentLimit = 20;
  double defaultFontSize = 16;
  ThemeMode themeMode = ThemeMode.system;

  void update({
    bool? autosave,
    int? autosaveSeconds,
    int? backupGenerations,
    int? recentLimit,
    double? defaultFontSize,
    ThemeMode? themeMode,
  }) {
    this.autosave = autosave ?? this.autosave;
    this.autosaveSeconds = autosaveSeconds ?? this.autosaveSeconds;
    this.backupGenerations = backupGenerations ?? this.backupGenerations;
    this.recentLimit = recentLimit ?? this.recentLimit;
    this.defaultFontSize = defaultFontSize ?? this.defaultFontSize;
    this.themeMode = themeMode ?? this.themeMode;
    notifyListeners();
  }
}
