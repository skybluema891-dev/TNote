import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  var terminationApproved = false
  private var documentsReady = false
  private var pendingDocuments: [String] = []

  func documentClientReady() {
    documentsReady = true
    deliverPendingDocuments()
  }

  private func deliverPendingDocuments() {
    guard documentsReady, !pendingDocuments.isEmpty,
      let controller = mainFlutterWindow?.contentViewController as? FlutterViewController
    else { return }
    let paths = pendingDocuments
    pendingDocuments.removeAll()
    let channel = FlutterMethodChannel(
      name: "com.tnote.app/documents",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.invokeMethod("openDocuments", arguments: paths)
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminationApproved, let window = mainFlutterWindow, window.isVisible else {
      return .terminateNow
    }
    // Cmd-Q and the Dock must use the same save confirmation and lock cleanup
    // as the window close button. Dart approves termination after shutdown.
    window.performClose(nil)
    return .terminateCancel
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    // FlutterAppDelegate implements openURLs, so AppKit does not call openFiles.
    let documents = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "tnote" }
    pendingDocuments.append(contentsOf: documents.map { $0.path })
    deliverPendingDocuments()
    let otherURLs = urls.filter { !$0.isFileURL || $0.pathExtension.lowercased() != "tnote" }
    if !otherURLs.isEmpty {
      super.application(application, open: otherURLs)
    }
  }

  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    // Keep cold-launch Finder events until the Dart workspace is ready.
    pendingDocuments.append(contentsOf: filenames)
    deliverPendingDocuments()
    sender.reply(toOpenOrPrint: .success)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
