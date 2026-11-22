import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/editor_position.dart';
import 'update_service.dart';

class UpdateResume {
  const UpdateResume({
    required this.paths,
    this.activePath,
    this.documentId,
    this.tabId,
    this.position,
  });
  final List<String> paths;
  final String? activePath;
  final String? documentId;
  final String? tabId;
  final EditorPosition? position;

  Map<String, Object?> toJson() => {
    'paths': paths,
    'activePath': activePath,
    'documentId': documentId,
    'tabId': tabId,
    'position': position?.toJson(),
  };

  factory UpdateResume.fromJson(Map<String, dynamic> json) => UpdateResume(
    paths: (json['paths'] as List<dynamic>).cast<String>(),
    activePath: json['activePath'] as String?,
    documentId: json['documentId'] as String?,
    tabId: json['tabId'] as String?,
    position: json['position'] == null
        ? null
        : EditorPosition.fromJson(json['position'] as Map<String, dynamic>),
  );
}

class WindowsUpdateSession {
  WindowsUpdateSession(Directory support, {this.managedSetup})
    : directory = Directory(p.join(support.path, 'updates'));

  final Directory directory;
  final File? managedSetup;
  File get installer =>
      managedSetup ?? File(p.join(directory.path, 'TNoteSetup.exe'));
  File get _resume => File(p.join(directory.path, 'reopen.json'));

  static const _channel = MethodChannel('tnote/windows_installation');

  Future<bool> isInstalled() async {
    if (!UpdateService.supportsWindowsInstaller) return false;
    final registered = await _channel.invokeMethod<String>(
      'getInstallDirectory',
    );
    if (registered == null) return false;
    final running = File(Platform.resolvedExecutable);
    return p.basename(running.path).toLowerCase() == 'tnote.exe' &&
        p.equals(p.normalize(registered), p.normalize(running.parent.path));
  }

  Future<UpdateResume?> takeResume() async {
    try {
      if (!await _resume.exists()) return null;
      final json =
          jsonDecode(await _resume.readAsString()) as Map<String, dynamic>;
      final resume = UpdateResume.fromJson(json);
      await _resume.delete();
      return resume;
    } catch (_) {
      return null;
    }
  }

  Future<void> confirmRunningVersion(String version, String build) async {
    try {
      if (!await isInstalled()) return;
      final installed = File(Platform.resolvedExecutable).parent;
      final rollback = Directory(
        p.join(installed.path, '.tnote-update-rollback'),
      );
      if (await FileSystemEntity.type(rollback.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return;
      }
      final marker = File(p.join(rollback.path, '.installed-version'));
      if (await FileSystemEntity.type(marker.path, followLinks: false) !=
              FileSystemEntityType.file ||
          (await marker.readAsString()).trim() != '$version+$build') {
        return;
      }
      await for (final entity in rollback.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is Link) return;
      }
      await rollback.delete(recursive: true);
    } catch (_) {
      // Keep rollback files when confirmation or cleanup is interrupted.
    }
  }

  Future<void> startInstaller(
    ReadyWindowsUpdate ready,
    UpdateService service,
    UpdateResume resume,
  ) async {
    if (!await isInstalled() ||
        !await service.verifyInstaller(ready.release, ready.installer)) {
      throw const FormatException('更新ファイルまたはインストール先を確認できません。');
    }
    await directory.create(recursive: true);
    final stagedResume = File('${_resume.path}.$pid.part');
    try {
      await stagedResume.writeAsString(
        jsonEncode(resume.toJson()),
        flush: true,
      );
      await stagedResume.rename(_resume.path);
      await Process.start(
        ready.installer.path,
        [
          '/VERYSILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
          '/NOCLOSEAPPLICATIONS',
          '/LOG=${p.join(directory.path, 'installation.log')}',
          '/TNOTEUPDATEPID=$pid',
        ],
        workingDirectory: ready.installer.parent.path,
        mode: ProcessStartMode.detached,
      );
    } catch (_) {
      if (await _resume.exists()) await _resume.delete();
      rethrow;
    } finally {
      if (await stagedResume.exists()) await stagedResume.delete();
    }
  }
}
