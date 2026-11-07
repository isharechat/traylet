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
    @Test func invalidEndpointSecretsAreNeverPersisted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("translation.json")
        let config = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        config.endpoint = "https://name:secret-password@example.invalid/v1?api_key=secret-query"
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
    @Test func settingsModelFetchRunsDirectlyAndReportsSuccessOnTheAction() async {
        let client = ModelListTranslationAI()
        let config = TranslationConfiguration(client: client)
        config.endpoint = "https://example.invalid/v1"
        await config.performSettingsAction(.models)
        #expect(config.models == ["alpha", "beta"])
        #expect(config.feedback(for: .models) == .success)
        #expect(config.runningAction == nil && !config.isBusy)
        #expect(await client.calls == 1)
    }
    @Test func settingsConnectionFailureStaysOnTheAction() async {
        let config = TranslationConfiguration(client: FailingTranslationAI())
        config.endpoint = "https://example.invalid/v1"
        await config.performSettingsAction(.connection)
        #expect(config.feedback(for: .connection) == .failure("服务暂时不可用，请稍后重试。"))
        #expect(config.runningAction == nil && !config.isBusy)
    }
    @Test func settingsDeepLTestRunsDirectly() async {
        let client = RecordingTranslationAI()
        let config = TranslationConfiguration(client: client)
        config.deeplKey = "unit-deepl-key"
        await config.performSettingsAction(.deeplTranslate)
        #expect(config.feedback(for: .deeplTranslate) == .success)
        #expect(await client.calls == 1)
    }
    @Test func settingsEmptyModelListReportsFailureOnTheAction() async {
        let config = TranslationConfiguration(client: EmptyModelListTranslationAI())
        config.endpoint = "https://example.invalid/v1"
        await config.performSettingsAction(.models)
        #expect(config.models.isEmpty)
        #expect(config.feedback(for: .models) == .failure("服务返回空模型列表；可手动填写。"))
    }
    @Test func changingSettingsClearsTransientActionResults() async {
        let config = TranslationConfiguration(client: ModelListTranslationAI())
        config.endpoint = "https://example.invalid/v1"
        await config.performSettingsAction(.models)
        config.model = "alpha"
        #expect(config.feedback(for: .models) == nil)
    }
    @Test func modelSearchMatchesCaseInsensitivelyAndTrimsTheQuery() {
        let models = ["gpt-4o", "Llama-3.1", "whisper-large-v3"]
        #expect(TranslationModelFilter.matching(models, query: "  GPT ") == ["gpt-4o"])
        #expect(TranslationModelFilter.matching(models, query: "large") == ["whisper-large-v3"])
        #expect(TranslationModelFilter.matching(models, query: "   ") == models)
        #expect(TranslationModelFilter.matching(models, query: "missing").isEmpty)
    }
    @Test func credentialsPersistAcrossReinitializationWithoutTouchingPreferencesFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("translation.json")
        let store = MemoryCredentialStore()
        let config = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI(), credentialStore: store)
        config.credential = "unit-ai-key"
        config.deeplKey = "unit-deepl-key"
        #expect(store.values[.aiAPIKey] == "unit-ai-key")
        #expect(store.values[.deeplAPIKey] == "unit-deepl-key")
        let reopened = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI(), credentialStore: store)
        #expect(reopened.credential == "unit-ai-key")
        #expect(reopened.deeplKey == "unit-deepl-key")
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(!saved.contains("unit-ai-key") && !saved.contains("unit-deepl-key"))
    }

    @Test func clearingACredentialRemovesItFromTheStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("translation.json")
        let store = MemoryCredentialStore()
        store.values[.aiAPIKey] = "old-key"
        let config = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI(), credentialStore: store)
        #expect(config.credential == "old-key")
        config.credential = ""
        #expect(store.values[.aiAPIKey] == nil)
    }

    @Test func storageRecoveryClearsStoredCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("translation.json")
        try Data("broken".utf8).write(to: file)
        let store = MemoryCredentialStore()
        store.values[.aiAPIKey] = "keep-ai"; store.values[.deeplAPIKey] = "keep-deepl"
        let config = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI(), credentialStore: store)
        #expect(config.credential == "keep-ai" && config.deeplKey == "keep-deepl")
        config.requestStorageRecovery(); config.confirmStorageRecovery()
        #expect(config.credential.isEmpty && config.deeplKey.isEmpty)
        #expect(store.values.isEmpty)
    }

    @Test func sameValueFocusWriteBackDoesNotCancelSettingsAction() async throws {
        let client = GatedModelListTranslationAI()
        let config = TranslationConfiguration(client: client)
        config.endpoint = "https://example.invalid/v1"
        config.runSettingsAction(.models)
        await client.waitUntilStarted()
        config.endpoint = config.endpoint
        config.model = config.model
        await client.releaseResponse()
        for _ in 0..<100 {
            if config.feedback(for: .models) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(config.feedback(for: .models) == .success)
        #expect(config.models == ["alpha", "beta"])
        #expect(!config.isBusy && config.runningAction == nil)
    }
}

@MainActor final class MemoryCredentialStore: TranslationCredentialStoring {
    var values: [TranslationCredential: String] = [:]
    func read(_ account: TranslationCredential) -> String? { values[account] }
    func write(_ value: String, for account: TranslationCredential) {
        values[account] = value.isEmpty ? nil : value
    }
    func remove(_ account: TranslationCredential) { values[account] = nil }
}

actor RecordingTranslationAI: TranslationAIClient {
    private(set) var calls = 0
    func perform(_ request: TranslationAIRequest) async throws -> TranslationAIResult {
        calls += 1
        return .text("你好。")
    }
}

actor ModelListTranslationAI: TranslationAIClient {
    private(set) var calls = 0
    func perform(_ request: TranslationAIRequest) async throws -> TranslationAIResult {
        calls += 1
        return .models(["alpha", "beta"])
    }
}

actor GatedModelListTranslationAI: TranslationAIClient {
    private var called = false
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func perform(_ request: TranslationAIRequest) async throws -> TranslationAIResult {
        called = true
        started?.resume()
        started = nil
        await withCheckedContinuation { release = $0 }
        return .models(["alpha", "beta"])
    }
    func waitUntilStarted() async {
        guard !called else { return }
        await withCheckedContinuation { started = $0 }
    }
    func releaseResponse() {
        release?.resume()
        release = nil
    }
}

struct EmptyModelListTranslationAI: TranslationAIClient {
    func perform(_ request: TranslationAIRequest) async throws -> TranslationAIResult { .models([]) }
}

struct FailingTranslationAI: TranslationAIClient {
    func perform(_ request: TranslationAIRequest) async throws -> TranslationAIResult { throw TranslationAIFailure.server }
}
