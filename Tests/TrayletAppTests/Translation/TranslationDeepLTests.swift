import Foundation
import Testing
@testable import TrayletApp
import TrayletCore

@Suite("Translation DeepL and multiple engines") @MainActor
struct TranslationDeepLTests {
    private static let key = "test-key:fx"
    private func request(_ text: String = "Hello", source: String = "en", target: String = "zh-Hans", key: String = TranslationDeepLTests.key) -> TranslationAIRequest {
        .init(id: UUID(), action: .deeplTranslate, settings: .init(endpoint: TranslationDeepLLanguages.endpoint(forKey: key), model: "", credential: key), content: text, source: source, target: target)
    }

    @Test func deepLPostsJSONWithAuthKeyHeaderAndDeepLCodes() async throws {
        let transport = TranslationStubHTTP(status: 200, body: #"{"translations":[{"detected_source_language":"EN","text":"你好"}]}"#)
        let sent = request()
        #expect(sent.destination == "https://api-free.deepl.com/v2/translate")
        #expect(try await TranslationOpenAIClient(transport: transport).perform(sent) == .text("你好"))
        let http = try #require(await transport.requests.first)
        #expect(http.httpMethod == "POST" && http.url?.path == "/v2/translate")
        #expect(http.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key test-key:fx")
        #expect(http.url?.absoluteString.contains("test-key") == false, "The key never appears in the URL")
        let bodyData = try #require(http.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(object["text"] as? [String] == ["Hello"] && object["source_lang"] as? String == "EN" && object["target_lang"] as? String == "ZH-HANS")
    }

    @Test func proKeysUseTheProHostAndAutoSourceOmitsSourceLanguage() async throws {
        let transport = TranslationStubHTTP(status: 200, body: #"{"translations":[{"text":"Hello"}]}"#)
        let sent = request(source: "auto", target: "en", key: "pro-key")
        #expect(sent.destination == "https://api.deepl.com/v2/translate")
        _ = try await TranslationOpenAIClient(transport: transport).perform(sent)
        let bodyData = try #require(await transport.requests.first?.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(object["source_lang"] == nil && object["target_lang"] as? String == "EN-US")
    }

    @Test func missingKeyUnsupportedLanguagesAndServiceFailuresAreSafeErrors() async throws {
        #expect(throws: TranslationAIFailure.missingCredential) { try TranslationAISettings(endpoint: "https://api.deepl.com", model: "", credential: "").url(for: .deeplTranslate) }
        let ok = TranslationStubHTTP(status: 200, body: #"{"translations":[{"text":"x"}]}"#)
        await #expect(throws: TranslationAIFailure.unsupportedLanguage) { try await TranslationOpenAIClient(transport: ok).perform(request(target: "vi")) }
        #expect(await ok.requests.isEmpty, "Rejected locally; nothing was sent")
        for (status, failure) in [(403, TranslationAIFailure.unauthorized), (456, .quotaExceeded), (429, .rateLimited), (413, .textTooLong), (503, .server)] {
            await #expect(throws: failure) { try await TranslationOpenAIClient(transport: TranslationStubHTTP(status: status, body: "{}")).perform(request()) }
        }
        await #expect(throws: TranslationAIFailure.malformed) { try await TranslationOpenAIClient(transport: TranslationStubHTTP(status: 200, body: #"{"translations":[]}"#)).perform(request()) }
        await #expect(throws: TranslationAIFailure.malformed) { try await TranslationOpenAIClient(transport: TranslationStubHTTP(status: 200, body: "not json")).perform(request()) }
    }

    @Test func enginesAreConfiguredTogetherKeyStaysInMemoryAndOlderFilesStillReadable() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-multi-\(UUID())/translation.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let config = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        #expect(config.availableEngines == [.system])
        config.aiEnabled = true; config.deeplEnabled = true; config.deeplKey = "secret-deepl-key"; config.engine = .deepl
        #expect(config.availableEngines == [.deepl, .system, .ai], "The default engine is first, the rest follow the saved order")
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(!saved.contains("secret-deepl-key"), "The DeepL key is never written to disk")
        let reopened = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        #expect(reopened.availableEngines == [.deepl, .system, .ai] && reopened.engine == .deepl && reopened.deeplKey.isEmpty)
        reopened.deeplEnabled = false
        #expect(reopened.engine == .system, "Disabling the selected engine falls back to system translation")
        // A file written before multi-engine support has no new keys; its selected AI engine stays enabled.
        let old = #"{"version":2,"engine":"ai","provider":"compatible","endpoint":"http://127.0.0.1:1234/v1","model":"m"}"#
        try Data(old.utf8).write(to: file)
        let migrated = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        #expect(migrated.engine == .ai && migrated.aiEnabled && !migrated.deeplEnabled)
        // A file that still names the removed DLX engine opens with system translation instead of failing.
        let dlx = #"{"version":2,"engine":"dlx","provider":"compatible","endpoint":"http://127.0.0.1:1234/v1","model":"","dlxEnabled":true,"dlxEndpoint":"http://127.0.0.1:1188"}"#
        try Data(dlx.utf8).write(to: file)
        let legacy = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        #expect(legacy.storageIssue == nil && legacy.engine == .system && !legacy.deeplEnabled)
    }

    @Test func deepLTranslationWaitsForConfirmationAndSendsOnlyThroughTheConfirmedRequest() async throws {
        let client = RecordingTranslationAI()
        let config = TranslationConfiguration(client: client)
        config.deeplKey = "k:fx"; config.engine = .deepl
        let controller = TranslationController(configuration: config, writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), speech: TranslationFakeSpeech())
        controller.flow.input = "Hello"
        await controller.submit()
        let preview = try #require(controller.preview)
        #expect(preview.action == .deeplTranslate && preview.destination == "https://api-free.deepl.com/v2/translate")
        #expect(controller.flow.phase == .awaitingConfirmation)
    }
}
