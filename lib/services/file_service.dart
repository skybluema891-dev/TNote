import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path/path.dart' as p;

import 'directory_access_service.dart';

class FileService {
  final DirectoryAccessService _directoryAccess = DirectoryAccessService();

  Future<bool> ensureDirectoryAccess(String path) =>
      _directoryAccess.ensureForFile(path);

  bool get usesMobileDocumentPicker => Platform.isIOS || Platform.isAndroid;
  static const type = XTypeGroup(
    label: 'TNote',
    extensions: ['tnote'],
    uniformTypeIdentifiers: ['public.data'],
  );
  Future<String?> pickOpen() async {
    if (Platform.isIOS || Platform.isAndroid) {
      return FlutterFileDialog.pickFile(
        params: const OpenFileDialogParams(
          allowedUtiTypes: ['com.tnote.document', 'public.data'],
          fileExtensionsFilter: ['tnote'],
          copyFileToCacheDir: false,
        ),
      );
    }
    return (await openFile(acceptedTypeGroups: [type]))?.path;
  }

  Future<String?> pickSave(String name, String? currentPath) async {
    if (Platform.isIOS || Platform.isAndroid) {
      throw UnsupportedError('先に保存する文書を準備してください。');
    }
    final location = await getSaveLocation(
      acceptedTypeGroups: [type],
      suggestedName: name.toLowerCase().endsWith('.tnote')
          ? name
          : '$name.tnote',
      initialDirectory: currentPath == null
          ? await _directoryAccess.lastDirectory()
          : p.dirname(currentPath),
    );
    if (location == null) return null;
    final path = location.path.toLowerCase().endsWith('.tnote')
        ? location.path
        : '${location.path}.tnote';
    return await ensureDirectoryAccess(path) ? path : null;
  }

  Future<String?> pickExport(String suggestedName, String extension) async {
    if (Platform.isIOS || Platform.isAndroid) {
      throw UnsupportedError('先に書き出すファイルを準備してください。');
    }
    final location = await getSaveLocation(
      acceptedTypeGroups: [
        XTypeGroup(label: extension.toUpperCase(), extensions: [extension]),
      ],
      suggestedName: '$suggestedName.$extension',
      initialDirectory: await _directoryAccess.lastDirectory(),
    );
    if (location == null) return null;
    final path = location.path.toLowerCase().endsWith('.$extension')
        ? location.path
        : '${location.path}.$extension';
    return await ensureDirectoryAccess(path) ? path : null;
  }

  Future<void> openNewWindow([String? path]) async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return;
    await Process.start(
      Platform.resolvedExecutable,
      path == null ? const [] : [path],
      mode: ProcessStartMode.detached,
    );
  }

  Future<String?> savePreparedFile(String sourcePath, String fileName) {
    return FlutterFileDialog.saveFile(
      params: SaveFileDialogParams(
        sourceFilePath: sourcePath,
        fileName: fileName,
      ),
    );
  }
}
