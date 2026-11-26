import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import TrayletCore
@testable import TrayletApp

@Suite("Translation screenshot input") @MainActor
struct TranslationImageInputTests {
    @Test func successfulRecognitionCommitsOnlyNewSourceWithoutSubmittingTranslation() async throws {
        let recognizer = SuspendedScreenshotRecognizer()
        let controller = seededController(recognizer)
        let task = controller.beginImageInput(try image())
        await recognizer.waitForCalls(1)
        #expect(controller.flow.input == "Existing source")
        #expect(controller.flow.output == "已有译文")
        await recognizer.resolve(0, result: .success("Recognized source\nSecond line"))
        await task.value
        #expect(controller.flow.input == "Recognized source\nSecond line")
        #expect(controller.flow.output == "已有译文")
        #expect(!controller.flow.outputIsCurrent)
        #expect(controller.flow.active == nil)
        #expect(controller.systemWork == nil)
        #expect(controller.preview == nil)
        #expect(controller.flow.phase == .idle)
    }
    @Test func recognitionFailurePreservesBothTextsAndExplainsFailure() async throws {
        let recognizer = SuspendedScreenshotRecognizer()
        let controller = seededController(recognizer)
        let task = controller.beginImageInput(try image())
        await recognizer.waitForCalls(1)
        await recognizer.resolve(0, result: .failure(FeatureIssue.unavailable("synthetic private error")))
        await task.value
        #expect(controller.flow.input == "Existing source")
        #expect(controller.flow.output == "已有译文")
        #expect(controller.flow.outputIsCurrent)
        #expect(controller.flow.phase == .failed("本机文字识别失败，请重新截图或直接输入。"))
    }
    @Test func editWhileRecognitionIsSuspendedRejectsLateText() async throws {
        let recognizer = SuspendedScreenshotRecognizer()
        let controller = seededController(recognizer)
        let task = controller.beginImageInput(try image())
        await recognizer.waitForCalls(1)
        controller.flow.input = "My correction"
        await recognizer.resolve(0, result: .success("Late recognized text"))
        await task.value
        #expect(controller.flow.input == "My correction")
        #expect(controller.flow.output == "已有译文")
        #expect(controller.flow.phase == .idle)
    }
    @Test func newerScreenshotOwnsInputWhenOlderRecognitionArrivesLast() async throws {
        let recognizer = SuspendedScreenshotRecognizer()
        let controller = seededController(recognizer)
        let first = controller.beginImageInput(try image())
        await recognizer.waitForCalls(1)
        let second = controller.beginImageInput(try image())
        await recognizer.waitForCalls(2)
        #expect(controller.flow.input == "Existing source")
        #expect(controller.flow.output == "已有译文")
        await recognizer.resolve(1, result: .success("Second screenshot text"))
        await second.value
        await recognizer.resolve(0, result: .success("Obsolete first screenshot"))
        await first.value
        #expect(controller.flow.input == "Second screenshot text")
        #expect(controller.flow.output == "已有译文")
        #expect(controller.flow.phase == .idle)
    }
    @Test func cancellationPreservesExistingResultAndRejectsLateSuccess() async throws {
        let recognizer = SuspendedScreenshotRecognizer()
        let controller = seededController(recognizer)
        let task = controller.beginImageInput(try image())
        await recognizer.waitForCalls(1)
        controller.cancel()
        #expect(controller.notice.contains("取消"))
        await recognizer.resolve(0, result: .success("Late recognized text"))
        await task.value
        #expect(controller.flow.input == "Existing source")
        #expect(controller.flow.output == "已有译文")
        #expect(controller.flow.outputIsCurrent)
        #expect(controller.flow.phase == .idle)
    }
    @Test func blankRecognitionPreservesExistingTextAndTranslation() async throws {
        let recognizer = SuspendedScreenshotRecognizer()
        let controller = seededController(recognizer)
        let task = controller.beginImageInput(try image())
        await recognizer.waitForCalls(1)
        #expect(controller.flow.input == "Existing source")
        #expect(controller.flow.output == "已有译文")
        await recognizer.resolve(0, result: .success(" \n\t"))
        await task.value
        #expect(controller.flow.input == "Existing source")
        #expect(controller.flow.output == "已有译文")
        #expect(controller.flow.outputIsCurrent)
        #expect(controller.flow.phase == .failed("未识别到文字，请重新截图或直接输入。"))
    }
    private func seededController(_ recognizer: SuspendedScreenshotRecognizer) -> TranslationController {
        let controller = TranslationController(configuration: TranslationConfiguration(client: RecordingTranslationAI()), writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), recognizer: recognizer, speech: TranslationFakeSpeech())
        controller.flow.input = "Existing source"
        let work = controller.flow.begin(engine: .system)!
        controller.flow.complete(work, text: "已有译文")
        return controller
    }
    private func image() throws -> RasterImage {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let cgImage = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))
        return try RasterImage(pngData: data as Data)
    }
}

actor SuspendedScreenshotRecognizer: TranslationRecognizing {
    private var calls = 0
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func recognize(_ image: RasterImage) async throws -> String {
        let id = calls; calls += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let ready = waiters.filter { calls >= $0.0 }
            waiters.removeAll { calls >= $0.0 }
            for (_, waiter) in ready { waiter.resume() }
        }
    }
    func waitForCalls(_ count: Int) async {
        if calls < count { await withCheckedContinuation { waiters.append((count, $0)) } }
    }
    func resolve(_ id: Int, result: Result<String, Error>) { pending.removeValue(forKey: id)?.resume(with: result) }
}
