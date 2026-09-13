import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    guard
      let controller = mainFlutterWindow?.contentViewController as? FlutterViewController
    else {
      sender.reply(toOpenOrPrint: .failure)
      return
    }
    let channel = FlutterMethodChannel(
      name: "com.tnote.app/documents",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.invokeMethod("openDocuments", arguments: filenames)
    sender.reply(toOpenOrPrint: .success)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
