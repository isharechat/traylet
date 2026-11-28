import Foundation
import Darwin
import Testing
@testable import TrayletApp

@Suite("Encrypted Credential Vault") @MainActor struct EncryptedCredentialVaultTests {
    @Test func roundTripSharedDirectoryEncryptsSecretsAndEnforcesRestrictedPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-vault-roundtrip-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }

        let vault = LocalEncryptedCredentialVault(directory: directory)
        let translationStore = LocalTranslationCredentialStore(vault: vault)
        let ocrStore = LocalOCRCredentialStore(vault: vault)

        translationStore.write("sk-translation-secret-1", for: .aiAPIKey)
        translationStore.write("deepl-secret-2", for: .deeplAPIKey)
        ocrStore.write("sk-ocr-secret-3")

        let reopenedVault = LocalEncryptedCredentialVault(directory: directory)
        let reopenedTranslation = LocalTranslationCredentialStore(vault: reopenedVault)
        let reopenedOCR = LocalOCRCredentialStore(vault: reopenedVault)

        #expect(reopenedTranslation.read(.aiAPIKey) == "sk-translation-secret-1")
        #expect(reopenedTranslation.read(.deeplAPIKey) == "deepl-secret-2")
        #expect(reopenedOCR.read() == "sk-ocr-secret-3")

        let vaultURL = directory.appendingPathComponent("credentials.enc")
        let keyURL = directory.appendingPathComponent(".credentials.key")
        let vaultData = try Data(contentsOf: vaultURL)
        let keyData = try Data(contentsOf: keyURL)

        for secret in ["sk-translation-secret-1", "deepl-secret-2", "sk-ocr-secret-3"] {
            #expect(vaultData.range(of: Data(secret.utf8)) == nil)
            #expect(keyData.range(of: Data(secret.utf8)) == nil)
        }

        let dirAttrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        let vaultAttrs = try FileManager.default.attributesOfItem(atPath: vaultURL.path)
        let keyAttrs = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        #expect(((dirAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o700)
        #expect(((vaultAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o600)
        #expect(((keyAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o600)
    }

    @Test func freshDirectoryCreatesNoFilesAndRemovingLastEntryDeletesVaultFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-vault-remove-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }

        let vault = LocalEncryptedCredentialVault(directory: directory)
        #expect(vault.read(service: "local.traylet.app.translation", account: "ai-api-key") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        let translationStore = LocalTranslationCredentialStore(vault: vault)
        let ocrStore = LocalOCRCredentialStore(vault: vault)
        translationStore.write("ai-secret", for: .aiAPIKey)
        translationStore.write("deepl-secret", for: .deeplAPIKey)
        ocrStore.write("ocr-secret")

        let vaultURL = directory.appendingPathComponent("credentials.enc")
        #expect(FileManager.default.fileExists(atPath: vaultURL.path))

        translationStore.remove(.aiAPIKey)
        #expect(translationStore.read(.aiAPIKey) == nil)
        #expect(translationStore.read(.deeplAPIKey) == "deepl-secret")
        #expect(ocrStore.read() == "ocr-secret")
        #expect(FileManager.default.fileExists(atPath: vaultURL.path))

        translationStore.write("", for: .deeplAPIKey)
        #expect(translationStore.read(.deeplAPIKey) == nil)
        #expect(ocrStore.read() == "ocr-secret")
        #expect(FileManager.default.fileExists(atPath: vaultURL.path))

        ocrStore.remove()
        #expect(ocrStore.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: vaultURL.path))
    }

    @Test func tamperedVaultCiphertextFailsAuthentication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-vault-tamper-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }

        let vault = LocalEncryptedCredentialVault(directory: directory)
        vault.write("sensitive-token", service: "local.traylet.app.ocr", account: "ocr-ai-api-key")
        #expect(vault.read(service: "local.traylet.app.ocr", account: "ocr-ai-api-key") == "sensitive-token")

        let vaultURL = directory.appendingPathComponent("credentials.enc")
        var bytes = try Data(contentsOf: vaultURL)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: vaultURL)

        #expect(vault.read(service: "local.traylet.app.ocr", account: "ocr-ai-api-key") == nil)
    }

    @Test func differentMachineOrUserBindingCannotDecryptVault() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-vault-binding-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = LocalEncryptedCredentialVault(
            directory: directory,
            machineIDProvider: { "machine-uuid-alpha" },
            userIDProvider: { 501 }
        )
        writer.write("bound-secret", service: "local.traylet.app.translation", account: "ai-api-key")
        #expect(writer.read(service: "local.traylet.app.translation", account: "ai-api-key") == "bound-secret")

        let otherMachine = LocalEncryptedCredentialVault(
            directory: directory,
            machineIDProvider: { "machine-uuid-beta" },
            userIDProvider: { 501 }
        )
        #expect(otherMachine.read(service: "local.traylet.app.translation", account: "ai-api-key") == nil)

        let otherUser = LocalEncryptedCredentialVault(
            directory: directory,
            machineIDProvider: { "machine-uuid-alpha" },
            userIDProvider: { 502 }
        )
        #expect(otherUser.read(service: "local.traylet.app.translation", account: "ai-api-key") == nil)
    }

    @Test func symlinkedVaultIsRejectedWithoutTouchingTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-vault-symlink-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let targetURL = directory.appendingPathComponent("outside-target.txt")
        let original = Data("untouched-target".utf8)
        try original.write(to: targetURL)

        let vaultURL = directory.appendingPathComponent("credentials.enc")
        try FileManager.default.createSymbolicLink(at: vaultURL, withDestinationURL: targetURL)

        let vault = LocalEncryptedCredentialVault(directory: directory)
        #expect(vault.read(service: "local.traylet.app.translation", account: "ai-api-key") == nil)
        vault.write("new-secret", service: "local.traylet.app.translation", account: "ai-api-key")
        #expect(vault.read(service: "local.traylet.app.translation", account: "ai-api-key") == nil)

        var linkInfo = stat()
        #expect(lstat(vaultURL.path, &linkInfo) == 0)
        #expect((linkInfo.st_mode & S_IFMT) == S_IFLNK)
        #expect(try Data(contentsOf: targetURL) == original)
    }

    @Test func writingSameSecretTwiceProducesDistinctCiphertext() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-vault-nonce-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }

        let vault = LocalEncryptedCredentialVault(directory: directory)
        let vaultURL = directory.appendingPathComponent("credentials.enc")

        vault.write("identical-secret", service: "local.traylet.app.translation", account: "ai-api-key")
        let firstCiphertext = try Data(contentsOf: vaultURL)

        vault.write("identical-secret", service: "local.traylet.app.translation", account: "ai-api-key")
        let secondCiphertext = try Data(contentsOf: vaultURL)

        #expect(firstCiphertext != secondCiphertext)
        #expect(vault.read(service: "local.traylet.app.translation", account: "ai-api-key") == "identical-secret")
    }
}
