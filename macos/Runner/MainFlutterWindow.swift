import Cocoa
import FlutterMacOS
import Security

class MainFlutterWindow: NSWindow {
  private var directoryAccess: DirectoryAccessService?
  private var documentChannel: FlutterMethodChannel?
  private var collaborationKeys: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    collaborationKeys = FlutterMethodChannel(
      name: "com.tnote.app/collaboration-keys",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    collaborationKeys?.setMethodCallHandler(handleCollaborationKey)
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

  // The local login keychain is available to both Developer ID and ad-hoc builds.
  // Keep room credentials on this Mac, outside the shared folder and preferences.
  private func handleCollaborationKey(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: String], let account = args["key"],
          account.range(of: "^tnote-(room|import)-[0-9a-f]{64}$", options: .regularExpression) != nil else {
      return result(FlutterError(code: "invalid_key", message: "参加情報が正しくありません。", details: nil))
    }
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "com.tnote.app.collaboration",
      kSecAttrAccount: account,
      kSecUseDataProtectionKeychain: false
    ]
    var status: OSStatus
    switch call.method {
    case "read":
      var read = query
      read[kSecReturnData] = true
      read[kSecMatchLimit] = kSecMatchLimitOne
      var item: CFTypeRef?
      status = SecItemCopyMatching(read as CFDictionary, &item)
      if status == errSecItemNotFound { return result(nil) }
      if status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) {
        return result(key)
      }
    case "write":
      guard let value = args["value"],
            value.range(of: "^[A-Za-z0-9_-]{43}=$", options: .regularExpression) != nil else {
        return result(FlutterError(code: "invalid_value", message: "参加キーが正しくありません。", details: nil))
      }
      let data = Data(value.utf8)
      var record = query
      record[kSecValueData] = data
      status = SecItemAdd(record as CFDictionary, nil)
      if status == errSecDuplicateItem {
        status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
      }
      if status == errSecSuccess { return result(nil) }
    default:
      return result(FlutterMethodNotImplemented)
    }
    result(FlutterError(code: "login_keychain", message: "ログインキーチェーンで参加キーを読み書きできません。", details: Int(status)))
  }
}
