import Social
import UniformTypeIdentifiers
import UIKit

final class ShareViewController: SLComposeServiceViewController {
  private let appGroup = "group.com.tnote.app"

  override func isContentValid() -> Bool { true }

  override func didSelectPost() {
    Task { @MainActor in
      do {
        let shared = try await collectText()
        try enqueue(text: shared.text, suggestedName: shared.name)
        extensionContext?.open(URL(string: "tnote://share")!) { _ in
          self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
      } catch {
        let alert = UIAlertController(
          title: "TNoteに追加できませんでした",
          message: error.localizedDescription,
          preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "閉じる", style: .default) { _ in
          self.extensionContext?.cancelRequest(withError: error)
        })
        present(alert, animated: true)
      }
    }
  }

  override func configurationItems() -> [Any]! { [] }

  private func collectText() async throws -> (text: String, name: String?) {
    var parts: [String] = []
    if !contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      parts.append(contentText)
    }
    var suggestedName: String?
    for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
      suggestedName = suggestedName ?? item.attributedTitle?.string
      if let attributedText = item.attributedContentText?.string,
        !attributedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        parts.append(attributedText)
      }
      for provider in item.attachments ?? [] {
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
          let value = try await load(provider, type: UTType.plainText.identifier) {
          if let text = value as? String { parts.append(text) }
          if let text = value as? NSAttributedString { parts.append(text.string) }
          if let data = value as? Data, let text = String(data: data, encoding: .utf8) {
            parts.append(text)
          }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
          let value = try await load(provider, type: UTType.url.identifier)
          if let url = value as? URL { parts.append(url.absoluteString) }
        }
      }
    }
    guard !parts.isEmpty else {
      throw NSError(domain: "TNoteShare", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "共有された文字を読み取れませんでした。"
      ])
    }
    return (parts.joined(separator: "\n\n"), suggestedName)
  }

  private func load(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding? {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: value)
        }
      }
    }
  }

  private func enqueue(text: String, suggestedName: String?) throws {
    guard let root = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroup
    ) else {
      throw NSError(domain: "TNoteShare", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "共有用の保存領域を使用できません。"
      ])
    }
    let directory = root.appendingPathComponent("SharedTextQueue", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let id = UUID().uuidString
    var payload: [String: Any] = [
      "id": id,
      "text": text,
      "createdAt": ISO8601DateFormatter().string(from: Date()),
    ]
    if let suggestedName, !suggestedName.isEmpty { payload["suggestedName"] = suggestedName }
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let temporary = directory.appendingPathComponent(".\(id).tmp")
    let destination = directory.appendingPathComponent("\(id).json")
    try data.write(to: temporary, options: [.atomic])
    try FileManager.default.moveItem(at: temporary, to: destination)
  }
}
