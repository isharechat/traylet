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

struct KeychainGenericPassword: Sendable {
    let service: String

    func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    func write(_ value: String, account: String) {
        guard !value.isEmpty else { remove(account: account); return }
        guard let data = value.data(using: .utf8) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var item = baseQuery(account: account)
        item.merge(attributes) { _, new in new }
        SecItemAdd(item as CFDictionary, nil)
    }

    func remove(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// macOS Keychain backing. Generic-password items are readable by the user's login keychain only.
final class KeychainTranslationCredentialStore: TranslationCredentialStoring {
    private let storage: KeychainGenericPassword

    init(service: String = "local.traylet.app.translation") {
        self.storage = KeychainGenericPassword(service: service)
    }

    func read(_ account: TranslationCredential) -> String? {
        storage.read(account: account.rawValue)
    }

    func write(_ value: String, for account: TranslationCredential) {
        storage.write(value, account: account.rawValue)
    }

    func remove(_ account: TranslationCredential) {
        storage.remove(account: account.rawValue)
    }
}
