import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Publish a fully written file on the same volume without replacing an
/// existing destination. Call on a worker isolate for network volumes.
void publishFile(String source, String destination) {
  final success = using((arena) {
    if (Platform.isWindows) {
      final move = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<
            Int32 Function(Pointer<Utf16>, Pointer<Utf16>),
            int Function(Pointer<Utf16>, Pointer<Utf16>)
          >('MoveFileW');
      String windowsPath(String path) {
        final absolute = File(path).absolute.path;
        if (absolute.startsWith(r'\\?\')) return absolute;
        if (absolute.startsWith(r'\\')) {
          return r'\\?\UNC\' + absolute.substring(2);
        }
        return r'\\?\' + absolute;
      }

      return move(
            windowsPath(source).toNativeUtf16(allocator: arena),
            windowsPath(destination).toNativeUtf16(allocator: arena),
          ) !=
          0;
    }
    final from = source.toNativeUtf8(allocator: arena);
    final to = destination.toNativeUtf8(allocator: arena);
    if (Platform.isMacOS || Platform.isIOS) {
      final rename = DynamicLibrary.process()
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Uint32),
            int Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >('renamex_np');
      return rename(from, to, 4) == 0; // RENAME_EXCL
    }
    final link = DynamicLibrary.process()
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)
        >('link');
    return link(from, to) == 0;
  });
  if (!success) {
    throw FileSystemException('ファイルを作成できません。保存先と同名ファイルを確認してください。', destination);
  }
}
