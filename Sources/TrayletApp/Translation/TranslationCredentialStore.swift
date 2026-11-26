import Foundation
import Security

/// The translation secrets that must survive relaunches without being written into the plain-text
/// preferences file next to non-secret settings.
enum TranslationCredential: String, Sendable {
    case aiAPIKey = "ai-api-key"
    case deeplAPIKey = "deepl-api-key"
}

@MainActor protocol TranslationCredentialStoring: AnyObject {
    func read(_ account: TranslationCredential) -> String?
    func write(_ value: String, for account: TranslationCredential)
    func remove(_ account: TranslationCredential)
}

/// macOS Keychain backing. Generic-password items are readable by the user's login keychain only.
final class KeychainTranslationCredentialStore: TranslationCredentialStoring {
    private let service: String

    init(service: String = "local.traylet.app.translation") {
        self.service = service
    }

    func read(_ account: TranslationCredential) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    func write(_ value: String, for account: TranslationCredential) {
        guard !value.isEmpty else { remove(account); return }
        guard let data = value.data(using: .utf8) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var item = baseQuery(account)
        item.merge(attributes) { _, new in new }
        SecItemAdd(item as CFDictionary, nil)
    }

    func remove(_ account: TranslationCredential) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private func baseQuery(_ account: TranslationCredential) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
    }
}
