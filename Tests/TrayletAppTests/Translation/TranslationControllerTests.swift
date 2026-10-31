import Foundation
import Testing
@testable import TrayletApp
import TrayletCore

@Suite("Translation controller") @MainActor
struct TranslationControllerTests {
    @Test func engineIconImmediatelyMarksPreviousOutputStaleAndKeepsItOnFailure() async throws {
        let config = TranslationConfiguration(client: EngineSwitchOfflineAI())
        config.setEnabled(.google, true)
        let controller = TranslationController(configuration: config, writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), speech: TranslationFakeSpeech())
        controller.flow.input = "Hello"; controller.flow.source = "en"
        await controller.submit()
        controller.finishSystem(try #require(controller.systemWork), text: "你好")
        #expect(controller.flow.outputIsCurrent)
        controller.select(.google)
        #expect(controller.selectedEngine == .google && controller.flow.output == "你好")
        #expect(!controller.flow.outputIsCurrent, "The old engine's result must be labeled previous before the replacement task runs")
        await controller.submissionTask?.value
        await controller.sendConfirmed(try #require(controller.preview))
        if case .failed = controller.flow.phase {} else { Issue.record("The synthetic offline engine should fail") }
        #expect(controller.flow.output == "你好" && !controller.flow.outputIsCurrent)
        controller.cancel()
    }

    @Test func engineIconRejectsOldSystemCompletionBeforeReplacementTaskStarts() async throws {
        let config = TranslationConfiguration(client: RecordingTranslationAI())
        config.setEnabled(.google, true)
        let controller = TranslationController(configuration: config, writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), speech: TranslationFakeSpeech())
        controller.flow.input = "Hello"; controller.flow.source = "en"
        await controller.submit()
        let obsolete = try #require(controller.systemWork)
        controller.select(.google)
        controller.finishSystem(obsolete, text: "obsolete system response")
        #expect(controller.flow.output.isEmpty && controller.systemWork == nil)
        await controller.submissionTask?.value
        #expect(controller.preview?.action == .googleTranslate)
        controller.cancel()
    }

    @Test func engineChangeMarksCompletedOutputAsPreviousResult() async throws {
        let config = TranslationConfiguration(client: RecordingTranslationAI())
        let controller = TranslationController(configuration: config, writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), speech: TranslationFakeSpeech())
        controller.flow.input = "Hello"
        await controller.submit()
        controller.finishSystem(try #require(controller.systemWork), text: "你好")
        #expect(controller.flow.outputIsCurrent)
        config.engine = .ai
        #expect(controller.flow.output == "你好")
        #expect(!controller.flow.outputIsCurrent)
    }
    @Test func inputChangeRejectsAIResultAlreadyInFlight() async throws {
        let client = TranslationSuspendedAI()
        let config = TranslationConfiguration(client: client)
        config.engine = .ai; config.model = "chosen"
        let controller = TranslationController(configuration: config, writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), speech: TranslationFakeSpeech())
        controller.flow.input = "First"
        await controller.submit()
        let preview = try #require(controller.preview)
        let task = Task { await controller.sendConfirmed(preview) }
        await client.waitUntilStarted()
        controller.flow.input = "Second"
        await client.resolve(.text("obsolete"))
        await task.value
        #expect(controller.flow.output.isEmpty)
        #expect(controller.flow.phase == .idle)
    }
    @Test func configurationChangeCancelsSystemHost() async throws {
        let config = TranslationConfiguration(client: RecordingTranslationAI())
        let controller = TranslationController(configuration: config, writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), speech: TranslationFakeSpeech())
        controller.flow.input = "Hello"
        await controller.submit()
        let work = try #require(controller.systemWork)
        config.engine = .ai
        #expect(controller.systemWork == nil)
        controller.finishSystem(work, text: "stale")
        #expect(controller.flow.output.isEmpty)
    }
    @Test func resourcesNeedExplicitPreparationAndKnownSource() async throws {
        let controller = TranslationController(writer: TranslationFakeWriter(), availability: TranslationDownloadableResources(), speech: TranslationFakeSpeech())
        controller.flow.input = "Hello"
        await controller.submit()
        #expect(controller.flow.phase == .resourceRequired)
        #expect(controller.systemWork == nil)
        controller.prepareLanguages()
        #expect(controller.systemWork == nil)
        controller.flow.source = "en"
        await controller.submit()
        controller.prepareLanguages()
        #expect(controller.systemWork != nil)
        #expect(controller.preparingResources)
        controller.clearOutput()
        #expect(controller.systemWork == nil)
        #expect(controller.flow.input == "Hello")
    }
    @Test func configurationChangeRejectsPreviewBeforeAnyRequest() async throws {
        let client = RecordingTranslationAI()
        let config = TranslationConfiguration(client: client)
        config.engine = .ai; config.model = "first"
        let controller = TranslationController(configuration: config, writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), speech: TranslationFakeSpeech())
        controller.flow.input = "Hello"
        await controller.submit()
        let preview = try #require(controller.preview)
        config.model = "second"
        await controller.sendConfirmed(preview)
        #expect(await client.calls == 0)
        #expect(controller.preview == nil)
    }
    @Test func closingHostRejectsCompletionAndReopenUsesNewIdentity() async throws {
        let controller = TranslationController(configuration: TranslationConfiguration(client: RecordingTranslationAI()), writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), speech: TranslationFakeSpeech())
        controller.flow.input = "Hello"
        await controller.submit()
        let first = try #require(controller.systemWork)
        controller.close()
        controller.finishSystem(first, text: "stale")
        #expect(controller.flow.output.isEmpty)
        await controller.submit()
        let next = try #require(controller.systemWork)
        #expect(first.id != next.id)
        controller.finishSystem(next, text: "你好")
        #expect(controller.flow.output == "你好")
    }
}
private struct EngineSwitchOfflineAI: TranslationAIClient {
    func perform(_ request: TranslationAIRequest) async throws -> TranslationAIResult { throw URLError(.notConnectedToInternet) }
}
@MainActor final class TranslationFakeWriter: TextOutputWriting {
    var copied: [String] = []
    func copyText(_ text: String) -> CopyOutcome { copied.append(text); return .copied }
}
struct TranslationFakeAvailability: TranslationResourceChecking {
    func status(text: String, source: String, target: String) async throws -> TranslationResourceState { .installed }
}
@MainActor final class TranslationFakeSpeech: TranslationSpeaking {
    var onFinish: (@MainActor () -> Void)?
    func speak(_ text: String, language: String) throws {}
    func stop() {}
}

struct TranslationDownloadableResources: TranslationResourceChecking {
    func status(text: String, source: String, target: String) async throws -> TranslationResourceState { .downloadable }
}
actor TranslationSuspendedAI: TranslationAIClient {
    private var response: CheckedContinuation<TranslationAIResult, Never>?
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func perform(_ request: TranslationAIRequest) async throws -> TranslationAIResult {
        started = true; waiter?.resume(); waiter = nil
        return await withCheckedContinuation { response = $0 }
    }
    func waitUntilStarted() async { if !started { await withCheckedContinuation { waiter = $0 } } }
    func resolve(_ result: TranslationAIResult) { response?.resume(returning: result); response = nil }
}
