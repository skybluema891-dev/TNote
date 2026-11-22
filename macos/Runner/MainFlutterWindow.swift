import Cocoa
import FlutterMacOS
import Security

class MainFlutterWindow: NSWindow {
  private var directoryAccess: DirectoryAccessService?
  private var documentChannel: FlutterMethodChannel?
  private var collaborationKeys: FlutterMethodChannel?
  private let keychainQueue = DispatchQueue(label: "com.tnote.app.collaboration-keychain")

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
    collaborationKeys?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      self.keychainQueue.async {
        self.handleCollaborationKey(call) { value in
          DispatchQueue.main.async { result(value) }
        }
      }
    }
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
  private lazy var adHocSignature: String? = {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code = code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode = staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let details = info as? [String: Any],
          (details[kSecCodeInfoCertificates as String] as? [Any] ?? []).isEmpty,
          let hash = details[kSecCodeInfoUnique as String] as? Data else { return nil }
    return hash.base64EncodedString()
  }()

  private func handleCollaborationKey(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any], let account = args["key"] as? String,
          account.range(of: "^tnote-(room|import)-[0-9a-f]{64}$", options: .regularExpression) != nil else {
      return result(FlutterError(code: "invalid_key", message: "参加情報が正しくありません。", details: nil))
    }
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "com.tnote.app.collaboration",
      kSecAttrAccount: account,
      kSecUseDataProtectionKeychain: false
    ]
    let permissionRecord = "TNoteAuthorizedSignature." + account
    var status: OSStatus
    switch call.method {
    case "read":
      var read = query
      if args["requestAccess"] as? Bool != true {
        read[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail
        if let signature = adHocSignature,
           UserDefaults.standard.string(forKey: permissionRecord) != signature {
          // An ad-hoc upgrade has a new code identity. Inspect existence only,
          // then let the owner choose whether to show the macOS password panel.
          var exists = read
          exists[kSecReturnAttributes] = true
          var attributes: CFTypeRef?
          status = SecItemCopyMatching(exists as CFDictionary, &attributes)
          if status == errSecItemNotFound { return result(nil) }
          return result(FlutterError(code: "key_access", message: "保存した参加キーへのアクセス許可が必要です。", details: nil))
        }
      }
      read[kSecReturnData] = true
      read[kSecMatchLimit] = kSecMatchLimitOne
      var item: CFTypeRef?
      status = SecItemCopyMatching(read as CFDictionary, &item)
      if status == errSecItemNotFound { return result(nil) }
      if status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) {
        if let signature = adHocSignature { UserDefaults.standard.set(signature, forKey: permissionRecord) }
        return result(key)
      }
    case "write":
      guard let value = args["value"] as? String,
            value.range(of: "^[A-Za-z0-9_-]{43}=$", options: .regularExpression) != nil else {
        return result(FlutterError(code: "invalid_value", message: "参加キーが正しくありません。", details: nil))
      }
      let data = Data(value.utf8)
      var record = query
      record[kSecValueData] = data
      record[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail
      status = SecItemAdd(record as CFDictionary, nil)
      if status == errSecSuccess, let signature = adHocSignature {
        UserDefaults.standard.set(signature, forKey: permissionRecord)
      }
      // A room ID is derived from its key. A saved enrollment is immutable.
      if status == errSecSuccess || status == errSecDuplicateItem { return result(nil) }
    default:
      return result(FlutterMethodNotImplemented)
    }
    let needsPermission = status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled
    result(FlutterError(code: needsPermission ? "key_access" : "login_keychain",
                        message: "ログインキーチェーンで参加キーを読み書きできません。", details: Int(status)))
  }
}
