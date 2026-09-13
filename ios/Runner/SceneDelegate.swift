import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
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
    channel.invokeMethod("openDocuments", arguments: urls.map(\.path))
  }

}
