import Foundation

@MainActor protocol OCRCredentialStoring: AnyObject {
    func read() -> String?
    func write(_ value: String)
    func remove()
}

/// Local AES-256-GCM encrypted credential store for OCR-specific AI API keys.
@MainActor final class LocalOCRCredentialStore: OCRCredentialStoring {
    private let vault: LocalEncryptedCredentialVault
    private let service: String
    private let account = "ocr-ai-api-key"

    convenience init(directory: URL, service: String = "local.traylet.app.ocr") {
        self.init(vault: LocalEncryptedCredentialVault(directory: directory), service: service)
    }

    init(vault: LocalEncryptedCredentialVault, service: String = "local.traylet.app.ocr") {
        self.vault = vault
        self.service = service
    }

    func read() -> String? {
        vault.read(service: service, account: account)
    }

    func write(_ value: String) {
        vault.write(value, service: service, account: account)
    }

    func remove() {
        vault.remove(service: service, account: account)
    }
}
