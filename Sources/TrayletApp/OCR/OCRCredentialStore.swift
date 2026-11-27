import Foundation
import Security

@MainActor protocol OCRCredentialStoring: AnyObject {
    func read() -> String?
    func write(_ value: String)
    func remove()
}

/// macOS Keychain backing for OCR-specific AI API keys.
final class KeychainOCRCredentialStore: OCRCredentialStoring {
    private let storage: KeychainGenericPassword
    private let account = "ocr-ai-api-key"

    init(service: String = "local.traylet.app.ocr") {
        self.storage = KeychainGenericPassword(service: service)
    }

    func read() -> String? {
        storage.read(account: account)
    }

    func write(_ value: String) {
        storage.write(value, account: account)
    }

    func remove() {
        storage.remove(account: account)
    }
}
