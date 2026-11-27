import Foundation
import Security

@MainActor protocol OCRCredentialStoring: AnyObject {
    func read() -> String?
    func write(_ value: String)
    func remove()
}

/// macOS Keychain backing for OCR-specific AI API keys.
final class KeychainOCRCredentialStore: OCRCredentialStoring {
    private let service: String
    private let account = "ocr-ai-api-key"

    init(service: String = "local.traylet.app.ocr") {
        self.service = service
    }

    func read() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    func write(_ value: String) {
        guard !value.isEmpty else { remove(); return }
        guard let data = value.data(using: .utf8) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var item = baseQuery()
        item.merge(attributes) { _, new in new }
        SecItemAdd(item as CFDictionary, nil)
    }

    func remove() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
