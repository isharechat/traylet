import Foundation
import Testing
@testable import TrayletApp
import TrayletCore

@Suite("Translation configuration") @MainActor
struct TranslationConfigurationTests {
    @Test func cancelledRecoveryPreservesOriginalAndMemoryCredential() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("translation.json")
        try Data("broken".utf8).write(to: file)
        let config = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        config.credential = "memory-only"
        config.requestStorageRecovery(); config.cancelStorageRecovery(); config.confirmStorageRecovery()
        #expect(try String(contentsOf: file, encoding: .utf8) == "broken")
        #expect(config.credential == "memory-only")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["translation.json"])
    }
    @Test func linkPlacedAfterInitializationCannotRedirectNewFileWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("translation.json")
        let untouched = directory.appendingPathComponent("must-not-be-created.json")
        let config = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: untouched)
        config.model = "new-model"
        #expect(config.storageIssue != nil)
        #expect(!FileManager.default.fileExists(atPath: untouched.path))
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeSymbolicLink)
    }
    @Test func damagedSettingsRequireConfirmationThenPreserveBackupAndReopenDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("translation.json")
        try Data("broken-v2-original".utf8).write(to: file)
        let config = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        config.credential = "temporary-key"; config.model = "unsaved"
        config.confirmStorageRecovery() // No prompt was requested.
        #expect(try String(contentsOf: file, encoding: .utf8) == "broken-v2-original")
        config.requestStorageRecovery()
        #expect(try String(contentsOf: file, encoding: .utf8) == "broken-v2-original")
        config.confirmStorageRecovery()
        #expect(config.storageIssue == nil)
        #expect(config.credential.isEmpty)
        #expect(config.engine == .system)
        #expect(config.model.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasSuffix(".backup") }
        #expect(backups.count == 1)
        if let backup = backups.first {
            #expect(try String(contentsOf: backup, encoding: .utf8) == "broken-v2-original")
            #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let reopened = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        #expect(reopened.storageIssue == nil)
        reopened.model = "saved-again"
        #expect(TranslationConfiguration(storageURL: file, client: RecordingTranslationAI()).model == "saved-again")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
    @Test(arguments: [false, true]) func linkedLeafOrDirectoryCannotBeReadOrReplaced(directoryLink: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let original = real.appendingPathComponent("translation.json")
        try Data("preserve-target".utf8).write(to: original)
        let link = directory.appendingPathComponent(directoryLink ? "linked-directory" : "linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directoryLink ? real : original)
        let file = directoryLink ? link.appendingPathComponent("translation.json") : link
        let config = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        #expect(config.storageIssue != nil)
        config.credential = "temporary-key"; config.model = "changed"
        config.requestStorageRecovery(); config.confirmStorageRecovery()
        #expect(config.storageIssue != nil)
        #expect(config.credential.isEmpty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "preserve-target")
        #expect((try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType) == .typeSymbolicLink)
    }
    @Test func newSettingsUsePrivateDirectoryAndFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("translation.json")
        let config = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        config.model = "chosen"
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o700)
        #expect(fileMode?.intValue == 0o600)
    }
    @Test func newConfigurationStoresNoCredentialAndLoadsOnlyVersionTwo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("translation.json")
        let config = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        config.model = "chosen"
        config.credential = "unit-memory-only"
        let data = try Data(contentsOf: file)
        #expect(!String(decoding: data, as: UTF8.self).contains("unit-memory-only"))
        let reopened = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        #expect(reopened.model == "chosen")
        #expect(reopened.credential.isEmpty)
        try Data("broken".utf8).write(to: file)
        let damaged = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        #expect(damaged.storageIssue != nil)
        damaged.model = "replacement"
        #expect(try String(contentsOf: file, encoding: .utf8) == "broken")
    }
    @Test func onePreviewCanOnlySendOnce() async throws {
        let client = RecordingTranslationAI()
        let config = TranslationConfiguration(client: client)
        config.model = "chosen"
        config.request(.modelTest)
        let preview = try #require(config.preview)
        await config.confirm(preview)
        await config.confirm(preview)
        #expect(await client.calls == 1)
    }
    @Test func invalidEndpointSecretsAreNeverPersisted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("translation.json")
        let config = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        config.endpoint = "https://name:secret-password@example.invalid/v1?api_key=secret-query"
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
    @Test func diagnosticsNeverExposeCredentialEcho() async throws {
        let config = TranslationConfiguration(client: CredentialEchoTranslationAI())
        config.model = "test-model"
        config.credential = "unit-secret-credential"
        config.request(.modelTest)
        await config.confirm(try #require(config.preview))
        #expect(!config.status.contains("unit-secret-credential"))
        #expect(config.status.contains("已隐藏"))
    }
    @Test func diagnosticTruncationCannotRevealPartOfCredential() async throws {
        let config = TranslationConfiguration(client: LongCredentialEchoTranslationAI())
        config.model = "test-model"
        config.credential = "SYNTHETIC-PRIVATE-KEY"
        config.request(.modelTest)
        await config.confirm(try #require(config.preview))
        #expect(!config.status.contains("SYNTHETIC"))
        #expect(config.status.contains("已隐藏"))
    }
    @Test func previewRequiresFreshExplicitConfirmation() async throws {
        let client = RecordingTranslationAI()
        let config = TranslationConfiguration(client: client)
        config.endpoint = "https://example.invalid/v1"
        config.model = "test-model"
        config.request(.modelTest)
        #expect(await client.calls == 0)
        let preview = try #require(config.preview)
        #expect(preview.content == "Hello.")
        #expect(preview.destination == "https://example.invalid/v1/chat/completions")
        config.endpoint = "https://other.invalid/v1"
        await config.confirm(preview)
        #expect(await client.calls == 0)
    }
}
actor RecordingTranslationAI: TranslationAIClient {
    private(set) var calls = 0
    func perform(_ request: TranslationAIRequest) async throws -> TranslationAIResult {
        calls += 1
        return .text("你好。")
    }
}

struct CredentialEchoTranslationAI: TranslationAIClient {
    func perform(_ request: TranslationAIRequest) async throws -> TranslationAIResult { .text("echo unit-secret-credential") }
}

struct LongCredentialEchoTranslationAI: TranslationAIClient {
    func perform(_ request: TranslationAIRequest) async throws -> TranslationAIResult {
        .text(String(repeating: "x", count: 4080) + "SYNTHETIC-PRIVATE-KEY")
    }
}
