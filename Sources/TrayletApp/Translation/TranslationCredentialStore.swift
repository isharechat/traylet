import Foundation

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

/// Local AES-256-GCM encrypted credential store for translation API keys.
@MainActor final class LocalTranslationCredentialStore: TranslationCredentialStoring {
    private let vault: LocalEncryptedCredentialVault
    private let service: String

    convenience init(directory: URL, service: String = "local.traylet.app.translation") {
        self.init(vault: LocalEncryptedCredentialVault(directory: directory), service: service)
    }

    init(vault: LocalEncryptedCredentialVault, service: String = "local.traylet.app.translation") {
        self.vault = vault
        self.service = service
    }

    func read(_ account: TranslationCredential) -> String? {
        vault.read(service: service, account: account.rawValue)
    }

    func write(_ value: String, for account: TranslationCredential) {
        vault.write(value, service: service, account: account.rawValue)
    }

    func remove(_ account: TranslationCredential) {
        vault.remove(service: service, account: account.rawValue)
    }
}
