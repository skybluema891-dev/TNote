import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private let appGroup = "group.com.tnote.app"
  private var dartReady = false
  private var pendingDocuments: [String] = []
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    let urls = connectionOptions.urlContexts.map(\.url)
    if !urls.isEmpty {
      DispatchQueue.main.async { [weak self] in self?.open(urls) }
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    open(URLContexts.map(\.url))
  }

  private func open(_ urls: [URL]) {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(
      name: "com.tnote.app/documents",
      binaryMessenger: controller.binaryMessenger
    )
    if urls.contains(where: { $0.scheme == "tnote" }), dartReady {
      channel.invokeMethod("sharedTextAvailable", arguments: nil)
    }
    let files = urls.filter(\.isFileURL)
    pendingDocuments.append(contentsOf: files.map(\.path))
    deliverPendingDocuments(channel)
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(
      name: "com.tnote.app/documents",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      switch call.method {
      case "documentsReady":
        self.dartReady = true
        self.deliverPendingDocuments(channel)
        result(nil)
      case "consumeSharedText":
        result(self.queuedSharedText())
      case "acknowledgeSharedText":
        guard let id = call.arguments as? String else {
          result(FlutterError(code: "INVALID_ID", message: "共有データの識別子がありません。", details: nil))
          return
        }
        self.removeSharedText(id: id)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func deliverPendingDocuments(_ channel: FlutterMethodChannel) {
    guard dartReady, !pendingDocuments.isEmpty else { return }
    let paths = pendingDocuments
    pendingDocuments.removeAll()
    channel.invokeMethod("openDocuments", arguments: paths)
  }

  private func queueDirectory() -> URL? {
    FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
      .appendingPathComponent("SharedTextQueue", isDirectory: true)
  }

  private func queuedSharedText() -> [[String: Any]] {
    guard let directory = queueDirectory(),
      let urls = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.creationDateKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }
    return urls
      .filter { $0.pathExtension == "json" }
      .compactMap { url in
        guard let data = try? Data(contentsOf: url),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return value
      }
      .sorted {
        ($0["createdAt"] as? String ?? "") < ($1["createdAt"] as? String ?? "")
      }
  }

  private func removeSharedText(id: String) {
    guard let directory = queueDirectory() else { return }
    let safeID = id.replacingOccurrences(of: "/", with: "_")
    try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(safeID).json"))
  }

}
