import AppKit
import Foundation
import Testing
import TrayletCore
@testable import TrayletApp

@Suite("Translation Retry") @MainActor struct TranslationRetryTests {
    @Test func retryUsesANewSystemHostAndKeepsThePreviousOutputUntilSuccess() async throws {
        let controller = TranslationController(configuration: TranslationConfiguration(client: RetryOnceAI()), writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), speech: TranslationFakeSpeech())
        controller.flow.input = "Hello"; controller.flow.source = "en"
        await controller.submit()
        controller.finishSystem(try #require(controller.systemWork), text: "以前的译文")
        await controller.submit()
        let failed = try #require(controller.systemWork)
        controller.failSystem(failed)
        #expect(controller.canRetrySubmission && controller.flow.output == "以前的译文")
        controller.retrySubmission()
        #expect(!controller.canRetrySubmission)
        await (try #require(controller.submissionTask)).value
        let retried = try #require(controller.systemWork)
        #expect(retried.id != failed.id && retried.text == "Hello")
        controller.finishSystem(failed, text: "迟到的旧请求")
        #expect(controller.flow.output == "以前的译文")
        controller.finishSystem(retried, text: "本次重试成功")
        #expect(controller.flow.output == "本次重试成功" && !controller.canRetrySubmission)
        controller.cancel()
    }
    @Test func explicitOnlineRetryUsesTheSameApprovedDestinationOnlyOnce() async throws {
        let client = RetryOnceAI()
        // Use the recorded fake itself, never a URLSession or real endpoint.
        let config = TranslationConfiguration(client: client)
        config.engine = .ai; config.model = "synthetic-model"
        let controller = TranslationController(configuration: config, writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), speech: TranslationFakeSpeech())
        controller.flow.input = "Retry this synthetic sentence."; controller.flow.source = "en"
        await controller.submit()
        await controller.sendConfirmed(try #require(controller.preview))
        #expect(controller.canRetrySubmission)
        controller.retrySubmission()
        let retry = try #require(controller.submissionTask)
        #expect(!controller.canRetrySubmission)
        controller.retrySubmission()
        await retry.value
        let requests = await client.requests
        #expect(requests.count == 2)
        #expect(requests.map(\.content) == ["Retry this synthetic sentence.", "Retry this synthetic sentence."])
        #expect(requests[0].id != requests[1].id && requests[0].destination == requests[1].destination)
        #expect(controller.flow.output == "合成重试结果" && !controller.canRetrySubmission)
        controller.cancel()
    }
    @Test(arguments: ["input", "source", "target", "engine", "configuration", "cancel", "close"])
    func changingTheRequestOrClosingWithdrawsOldRetry(_ change: String) async throws {
        let controller = TranslationController(configuration: TranslationConfiguration(client: RetryOnceAI()), writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), speech: TranslationFakeSpeech())
        controller.flow.input = "Hello"; controller.flow.source = "en"
        await controller.submit()
        let failed = try #require(controller.systemWork)
        controller.failSystem(failed)
        #expect(controller.canRetrySubmission)
        switch change {
        case "input": controller.flow.input = "Different input"
        case "source": controller.flow.source = "fr"
        case "target": controller.flow.target = "ja"
        case "engine": controller.configuration.engine = .ai
        case "configuration": controller.configuration.model = "different-model"
        case "cancel": controller.cancel()
        default: controller.close()
        }
        #expect(!controller.canRetrySubmission)
        controller.retrySubmission()
        #expect(controller.submissionTask == nil && controller.systemWork == nil)
    }
    @Test(arguments: ["cancel", "close", "input", "language", "engine", "configuration"])
    func queuedRetryWithdrawnBeforeItsTaskRunsCannotSendOrReviveWork(_ change: String) async throws {
        let client = RetryOnceAI()
        let configuration = TranslationConfiguration(client: client)
        configuration.engine = .ai; configuration.model = "synthetic-model"
        let controller = TranslationController(configuration: configuration, writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), speech: TranslationFakeSpeech())
        controller.flow.input = "This retry will be withdrawn"; controller.flow.source = "en"
        await controller.submit()
        await controller.sendConfirmed(try #require(controller.preview))
        try #require(controller.canRetrySubmission)
        controller.retrySubmission()
        let queued = try #require(controller.submissionTask)
        // Deliberately do not yield between scheduling and withdrawal.
        switch change {
        case "cancel": controller.cancel()
        case "close": controller.close()
        case "input": controller.flow.input = "Changed after retry was queued"
        case "language": controller.flow.target = "ja"
        case "engine": configuration.engine = .system
        default: configuration.model = "changed-model"
        }
        await queued.value
        #expect(await client.requests.count == 1)
        #expect(controller.flow.phase == .idle && controller.flow.active == nil)
        #expect(controller.preview == nil && controller.systemWork == nil && !controller.canRetrySubmission)
        controller.cancel()
    }
    @Test func cancellationRejectsALateResultFromRetriedOnlineWork() async throws {
        let client = RetryPendingAI()
        let configuration = TranslationConfiguration(client: client)
        configuration.engine = .ai; configuration.model = "synthetic-model"
        let controller = TranslationController(configuration: configuration, writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), speech: TranslationFakeSpeech())
        controller.flow.input = "Synthetic pending retry"; controller.flow.source = "en"
        let prior = try #require(controller.flow.begin(engine: .ai))
        controller.flow.complete(prior, text: "保留之前的成功结果")
        await controller.submit()
        await controller.sendConfirmed(try #require(controller.preview))
        #expect(controller.canRetrySubmission)
        controller.retrySubmission()
        let retry = try #require(controller.submissionTask)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await client.secondPending), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let pending = await client.secondPending
        guard pending else { controller.cancel(); await client.resolve(); await retry.value; Issue.record("Retry never reached the fake transport"); return }
        controller.cancel()
        await client.resolve(); await retry.value
        #expect(controller.flow.output == "保留之前的成功结果" && controller.flow.phase == .idle && !controller.canRetrySubmission)
    }
    @Test(arguments: ["missingModel", "invalidEndpoint", "missingDeepLKey"])
    func configurationMustBeCorrectedBeforeRetryCanBeUseful(_ failure: String) async throws {
        let client = RetryOnceAI()
        let configuration = TranslationConfiguration(client: client)
        configuration.engine = failure == "missingDeepLKey" ? .deepl : .ai
        if failure != "missingModel" { configuration.model = "synthetic-model" }
        if failure == "invalidEndpoint" { configuration.endpoint = "https://example.invalid/v1?unsupported=query" }
        let controller = TranslationController(configuration: configuration, writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), speech: TranslationFakeSpeech())
        controller.flow.input = "Synthetic configuration failure"
        await controller.submit()
        #expect(!controller.canRetrySubmission && controller.preview == nil)
        controller.retrySubmission()
        #expect(controller.submissionTask == nil && controller.systemWork == nil)
        #expect(await client.requests.isEmpty)
        controller.cancel()
    }
    @Test func failedOCRCannotOfferAnUnrelatedTranslationRetry() async throws {
        let controller = TranslationController(configuration: TranslationConfiguration(client: RetryOnceAI()), writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), recognizer: RetryFailingOCR(), speech: TranslationFakeSpeech())
        controller.flow.input = "Existing source"; controller.flow.source = "en"
        await controller.submit(); controller.failSystem(try #require(controller.systemWork))
        #expect(controller.canRetrySubmission)
        let bitmap = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(bitmap.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        await controller.beginImageInput(try RasterImage(pngData: png)).value
        #expect(!controller.canRetrySubmission && controller.flow.input == "Existing source")
        controller.retrySubmission()
        #expect(controller.submissionTask == nil)
        controller.cancel()
    }
}

private actor RetryOnceAI: TranslationAIClient {
    private(set) var requests: [TranslationAIRequest] = []
    func perform(_ request: TranslationAIRequest) async throws -> TranslationAIResult {
        requests.append(request)
        if requests.count == 1 { throw URLError(.timedOut) }
        return .text("合成重试结果")
    }
}
private actor RetryPendingAI: TranslationAIClient {
    private var requests = 0
    private var pending: CheckedContinuation<TranslationAIResult, Never>?
    var secondPending: Bool { pending != nil }
    func perform(_ request: TranslationAIRequest) async throws -> TranslationAIResult {
        requests += 1
        if requests == 1 { throw URLError(.networkConnectionLost) }
        return await withCheckedContinuation { pending = $0 }
    }
    func resolve() { pending?.resume(returning: .text("不应覆盖的迟到译文")); pending = nil }
}
private struct RetryFailingOCR: TranslationRecognizing {
    func recognize(_ image: RasterImage) async throws -> String { throw FeatureIssue.unavailable("Synthetic OCR failure") }
}
