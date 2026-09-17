import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'services/document_controller.dart';
import 'services/document_store.dart';
import 'services/recovery_store.dart';
import 'services/backup_service.dart';
import 'services/file_lock_service.dart';
import 'services/recent_files_service.dart';
import 'services/settings_service.dart';
import 'services/user_error.dart';
import 'services/platform_document_service.dart';
import 'services/directory_access_service.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  if (desktop) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    await windowManager.setMinimumSize(const Size(480, 420));
    await windowManager.setTitle('TNote');
  }
  try {
    await DirectoryAccessService().restore();
    final support = await getApplicationSupportDirectory();
    final settings = await SettingsService().load();
    final recents = RecentFilesService();
    await recents.load(limit: settings.recentLimit);
    final controller = DocumentController(
      store: DocumentStore(),
      recovery: RecoveryStore(Directory('${support.path}/recovery')),
      backups: BackupService(Directory('${support.path}/backups')),
      locks: FileLockService(Directory('${support.path}/locks')),
      recents: recents,
      settings: settings,
    );
    await controller.initialize();
    final initialPath = args
        .where((arg) => arg.toLowerCase().endsWith('.tnote'))
        .firstOrNull;
    controller.startupPath = initialPath;
    PlatformDocumentService.bind(controller);
    String version = '1.3.4';
    String buildNumber = '12';
    try {
      final package = await PackageInfo.fromPlatform();
      version = package.version;
      buildNumber = package.buildNumber;
    } catch (_) {}
    runApp(
      TNoteApp(
        controller: controller,
        desktop: desktop,
        version: version,
        buildNumber: buildNumber,
      ),
    );
  } catch (error) {
    if (desktop) await windowManager.setPreventClose(false);
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SelectableText('TNoteを起動できませんでした。\n${userError(error)}'),
          ),
        ),
      ),
    );
  }
}

