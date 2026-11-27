import Foundation
import Testing
@testable import TrayletApp

@Suite("OCR Configuration") @MainActor struct OCRConfigurationTests {
    @Test func persistsNonSecretSettingsAndKeepsKeyInCredentialStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-ocr-config-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ocr.json")
        let creds = MemoryOCRCredentialStore()

        let config = OCRConfiguration(storageURL: file, credentialStore: creds)
        config.defaultEngine = .ai
        config.autoCopy = true
        config.mergeLineBreaks = true
        config.reuseTranslationAI = false
        config.model = "qwen-vl-plus"
        config.credential = "secret-ocr-key"
        config.preset = .formula

        let disk = try String(contentsOf: file, encoding: .utf8)
        #expect(!disk.contains("secret-ocr-key"))
        #expect(creds.value == "secret-ocr-key")

        let reloaded = OCRConfiguration(storageURL: file, credentialStore: creds)
        #expect(reloaded.defaultEngine == .ai)
        #expect(reloaded.autoCopy)
        #expect(reloaded.mergeLineBreaks)
        #expect(!reloaded.reuseTranslationAI)
        #expect(reloaded.model == "qwen-vl-plus")
        #expect(reloaded.credential == "secret-ocr-key")
        #expect(reloaded.preset == .formula)
    }

    @Test func reusesTranslationEndpointAndCredentialWithOptionalModelOverride() {
        let translation = TranslationConfiguration()
        translation.provider = .compatible
        translation.endpoint = "https://example.com/v1"
        translation.model = "gpt-4o-mini"
        translation.credential = "tr-key"

        let ocr = OCRConfiguration(translationConfiguration: translation)
        ocr.reuseTranslationAI = true
        ocr.model = ""
        #expect(ocr.effectiveSettings.endpoint == "https://example.com/v1")
        #expect(ocr.effectiveSettings.credential == "tr-key")
        #expect(ocr.effectiveSettings.model == "gpt-4o-mini")

        ocr.model = "gpt-4o"
        #expect(ocr.effectiveSettings.model == "gpt-4o")
    }

    @Test func damagedFilePreservesBackupOnRecovery() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-ocr-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ocr.json")
        try Data("{corrupted".utf8).write(to: file)

        let config = OCRConfiguration(storageURL: file, credentialStore: MemoryOCRCredentialStore())
        #expect(config.storageIssue != nil)
        config.requestStorageRecovery()
        config.confirmStorageRecovery()
        #expect(config.storageIssue == nil)
        #expect(config.defaultEngine == .vision)
    }
}

@MainActor private final class MemoryOCRCredentialStore: OCRCredentialStoring {
    var value: String?
    func read() -> String? { value }
    func write(_ value: String) { self.value = value }
    func remove() { value = nil }
}
