import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var directoryAccess: DirectoryAccessService?
  private var documentChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    directoryAccess = DirectoryAccessService(
      messenger: flutterViewController.engine.binaryMessenger, window: self
    )

    documentChannel = FlutterMethodChannel(
      name: "com.tnote.app/documents",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    documentChannel?.setMethodCallHandler { call, result in
      switch call.method {
      case "prepareToTerminate":
        (NSApp.delegate as? AppDelegate)?.terminationApproved = true
        result(nil)
      case "documentsReady":
        (NSApp.delegate as? AppDelegate)?.documentClientReady()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
