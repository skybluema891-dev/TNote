import Cocoa
import FlutterMacOS

/// Grants only explicitly selected folders. Scope remains active while autosave,
/// SQLite sidecars and shared locks need it, and is released with the window.
final class DirectoryAccessService {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private let defaults = UserDefaults.standard
  private let bookmarkKey = "TNoteDirectoryBookmarksV1"
  private let lastKey = "TNoteLastDirectoryV1"
  private var active: [String: URL] = [:]

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    self.window = window
    channel = FlutterMethodChannel(
      name: "com.tnote.app/directory-access", binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      switch call.method {
      case "restore":
        self.restore()
        result(nil)
      case "lastDirectory":
        guard let path = self.defaults.string(forKey: self.lastKey) else {
          return result(nil)
        }
        let directory = URL(fileURLWithPath: path)
        if let restored = self.active[path] {
          result(restored.path)
        } else {
          result(self.active.values.contains { self.contains($0, directory) } ? path : nil)
        }
      case "ensureForFile":
        guard let path = call.arguments as? String, path.hasPrefix("/") else {
          return result(FlutterError(code: "invalid_path", message: "保存先のパスが不正です。", details: nil))
        }
        self.ensureDirectory(for: URL(fileURLWithPath: path), result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func canonical(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }

  private func contains(_ parent: URL, _ child: URL) -> Bool {
    let base = canonical(parent).pathComponents
    return canonical(child).pathComponents.starts(with: base)
  }

  private func restore() {
    let saved = defaults.dictionary(forKey: bookmarkKey) ?? [:]
    for (path, value) in saved where active[path] == nil {
      guard let data = value as? Data else { continue }
      do {
        var stale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else { continue }
        active[path] = url
        if stale {
          do { try persist(url, key: path) } catch {
            NSLog("TNote: folder permission must be renewed on a later launch")
          }
        }
      } catch {
        // Keep the saved bookmark and history. Re-selection can repair access.
        NSLog("TNote: could not restore a folder permission")
      }
    }
  }

  private func persist(_ url: URL, key: String) throws {
    let data = try url.bookmarkData(options: .withSecurityScope,
                                    includingResourceValuesForKeys: nil,
                                    relativeTo: nil)
    var saved = defaults.dictionary(forKey: bookmarkKey) ?? [:]
    saved[key] = data
    defaults.set(saved, forKey: bookmarkKey)
  }

  private func ensureDirectory(for file: URL, result: @escaping FlutterResult) {
    let directory = canonical(file.deletingLastPathComponent())
    // The sandbox container needs no external folder grant.
    if contains(URL(fileURLWithPath: NSHomeDirectory()), directory) {
      return result(true)
    }
    if active.values.contains(where: { contains($0, directory) }) {
      defaults.set(directory.path, forKey: lastKey)
      return result(true)
    }
    let panel = NSOpenPanel()
    panel.title = "保存先フォルダへのアクセス"
    panel.message = "文書の保存と自動保存に使用します。「\(directory.lastPathComponent)」フォルダを選択してください。次回起動時もこの選択を記憶します。"
    panel.prompt = "このフォルダを使用"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.directoryURL = directory
    let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard let self = self else { return result(false) }
      guard response == .OK, let selected = panel.url else { return result(false) }
      guard self.canonical(selected) == directory else {
        return result(FlutterError(code: "different_directory",
          message: "保存先と同じフォルダを選択してください。保存先を変更する場合は、保存操作をやり直してください。", details: nil))
      }
      let started = selected.startAccessingSecurityScopedResource()
      do {
        try self.persist(selected, key: directory.path)
        // Resolve the stored bookmark to obtain an explicit long-lived scope.
        if started { selected.stopAccessingSecurityScopedResource() }
        self.restore()
        guard self.active[directory.path] != nil else {
          return result(FlutterError(code: "folder_access",
            message: "フォルダへのアクセス権を取得できませんでした。フォルダを選び直してください。", details: nil))
        }
        self.defaults.set(directory.path, forKey: self.lastKey)
        result(true)
      } catch {
        if started { selected.stopAccessingSecurityScopedResource() }
        result(FlutterError(code: "folder_bookmark",
          message: "フォルダへのアクセス権を保存できませんでした。アクセス権を確認して、選び直してください。", details: nil))
      }
    }
    if let window = window {
      panel.beginSheetModal(for: window, completionHandler: finish)
    } else {
      panel.begin(completionHandler: finish)
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
    for url in active.values { url.stopAccessingSecurityScopedResource() }
  }
}
