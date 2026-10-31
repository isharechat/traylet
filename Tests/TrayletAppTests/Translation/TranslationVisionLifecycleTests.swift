import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import TrayletCore
@testable import TrayletApp

@Suite("Translation Vision lifecycle", .serialized)
struct TranslationVisionLifecycleTests {
    @Test func queuedCancellationFinishesWhileEarlierProcessorIsHeld() async throws {
        let (raster, pixels) = try fixture()
        let calls = Counter()
        let cancelled = Counter()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let recognizer = TranslationVisionOCR { _, _ in
            calls.increment()
            _ = release.wait(timeout: .now() + 2)
            return "recognized"
        }
        let first = Task { try await recognizer.recognize(raster, decoded: pixels) }
        #expect(await eventually { calls.value == 1 })
        let queued = Task {
            do { _ = try await recognizer.recognize(raster, decoded: pixels) }
            catch is CancellationError { cancelled.increment() }
            catch { Issue.record("Unexpected error: \(error)") }
        }
        try await Task.sleep(for: .milliseconds(30))
        queued.cancel(); queued.cancel()
        #expect(await eventually { cancelled.value == 1 })
        #expect(calls.value == 1)
        release.signal()
        #expect(try await first.value == "recognized")
        await queued.value
    }

    @Test func cancelledQueuedPixelsAreReleasedBeforeActiveWorkEnds() async throws {
        let (raster, pixels) = try fixture()
        let calls = Counter()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let recognizer = TranslationVisionOCR { _, _ in
            calls.increment()
            _ = release.wait(timeout: .now() + 3)
            return "active"
        }
        let first = Task { try await recognizer.recognize(raster, decoded: pixels) }
        #expect(await eventually { calls.value == 1 })
        // Each queued image owns 4 MiB of decoded pixels. No production pixels are used.
        for _ in 0..<12 {
            let (queued, weakPixels) = try queuedImage(recognizer)
            try await Task.sleep(for: .milliseconds(5))
            queued.cancel()
            await queued.value
            #expect(await eventually { weakPixels.image == nil })
        }
        #expect(calls.value == 1)
        release.signal()
        #expect(try await first.value == "active")
    }

    @Test(arguments: [false, true])
    func activeCancellationDiscardsLateResultAndKeepsOtherRecognizersSerial(throwsLate: Bool) async throws {
        let (raster, pixels) = try fixture()
        let entered = Counter()
        let cancelled = Counter()
        let nextEntered = Counter()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let firstOCR = TranslationVisionOCR { _, _ in
            entered.increment()
            _ = release.wait(timeout: .now() + 2)
            if throwsLate { throw ProbeFailure.failed }
            return "stale"
        }
        let first = Task {
            do { _ = try await firstOCR.recognize(raster, decoded: pixels); Issue.record("Cancelled active OCR succeeded") }
            catch is CancellationError { cancelled.increment() }
            catch { Issue.record("Late failure escaped cancellation: \(error)") }
        }
        #expect(await eventually { entered.value == 1 })
        first.cancel(); first.cancel()
        #expect(await eventually { cancelled.value == 1 })
        let nextOCR = TranslationVisionOCR { _, _ in nextEntered.increment(); return "current" }
        let next = Task { try await nextOCR.recognize(raster, decoded: pixels) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(nextEntered.value == 0)
        release.signal()
        #expect(try await next.value == "current")
        await first.value
        #expect(cancelled.value == 1)
        #expect(nextEntered.value == 1)
    }

    @Test func suppliedPixelsAreReusedAndOriginalPNGPathStillDecodes() async throws {
        let (raster, pixels) = try fixture()
        let supplied = TranslationVisionOCR { received, _ in
            #expect(received === pixels)
            return "same pixels"
        }
        #expect(try await supplied.recognize(raster, decoded: pixels) == "same pixels")
        let encoded = TranslationVisionOCR { received, _ in
            #expect(received.width == 2 && received.height == 2)
            return "decoded PNG"
        }
        #expect(try await encoded.recognize(raster) == "decoded PNG")
    }

    @Test func mismatchedPixelsNeverReachProcessor() async throws {
        let (raster, _) = try fixture()
        let (_, wrongPixels) = try fixture(width: 3)
        let calls = Counter()
        let recognizer = TranslationVisionOCR { _, _ in calls.increment(); return "unexpected" }
        do {
            _ = try await recognizer.recognize(raster, decoded: wrongPixels)
            Issue.record("Mismatched pixels accepted")
        } catch let error as FeatureIssue { #expect(error == .invalidInput("图片尺寸不匹配。")) }
        #expect(calls.value == 0)
    }

    @Test func existingSixKScreenshotBudgetIsPreserved() async throws {
        let (raster, pixels) = try fixture(width: 6_016, height: 3_384)
        let recognizer = TranslationVisionOCR { received, _ in
            #expect(received.width == 6_016 && received.height == 3_384)
            return "synthetic 6K"
        }
        // History owns its narrower 16M-pixel cap; native screenshot OCR retains RasterImage's cap.
        #expect(try await recognizer.recognize(raster, decoded: pixels) == "synthetic 6K")
        #expect(try await recognizer.recognize(raster) == "synthetic 6K")
    }

    @Test func outputBudgetUsesUTF8BytesAndAllowsExactLimit() async throws {
        let (raster, pixels) = try fixture()
        let exact = String(repeating: "a", count: 128 * 1_024)
        let allowed = TranslationVisionOCR { _, _ in exact }
        #expect(try await allowed.recognize(raster, decoded: pixels) == exact)
        let excessive = TranslationVisionOCR { _, _ in String(repeating: "界", count: 43_691) }
        do {
            _ = try await excessive.recognize(raster, decoded: pixels)
            Issue.record("Oversized OCR output accepted")
        } catch let error as FeatureIssue { #expect(error == .invalidInput("识别文字过长。")) }
    }

    @Test func repeatedCancellationSuccessAndFailureRemainUsable() async throws {
        let (raster, pixels) = try fixture()
        for iteration in 0..<500 {
            let recognizer = TranslationVisionOCR { _, _ in
                if iteration % 3 == 1 { throw ProbeFailure.failed }
                return "recognized"
            }
            // An event starts at zero; all paths signal once and consume that signal once.
            let start = DispatchSemaphore(value: 0)
            let task = Task {
                Self.waitForStart(start)
                return try await recognizer.recognize(raster, decoded: pixels)
            }
            if iteration % 3 == 2 { task.cancel(); task.cancel() }
            start.signal()
            do {
                let value = try await task.value
                #expect(iteration % 3 == 0)
                #expect(value == "recognized")
            } catch is CancellationError { #expect(iteration % 3 == 2) }
            catch is ProbeFailure { #expect(iteration % 3 == 1) }
        }
    }

    private enum ProbeFailure: Error { case failed }
    private static func waitForStart(_ semaphore: DispatchSemaphore) {
        _ = semaphore.wait(timeout: .now() + 1)
    }

    private func queuedImage(_ recognizer: TranslationVisionOCR) throws -> (Task<Void, Never>, WeakPixels) {
        let (raster, pixels) = try fixture(width: 1_024, height: 1_024)
        let weakPixels = WeakPixels(pixels)
        let task = Task {
            do { _ = try await recognizer.recognize(raster, decoded: pixels); Issue.record("Cancelled queued image succeeded") }
            catch is CancellationError { }
            catch { Issue.record("Unexpected error: \(error)") }
        }
        return (task, weakPixels)
    }
    private final class WeakPixels: @unchecked Sendable {
        weak var image: CGImage?
        init(_ image: CGImage) { self.image = image }
    }

    private func fixture(width: Int = 2, height: Int = 2) throws -> (RasterImage, CGImage) {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return (try RasterImage(pngData: data as Data), image)
    }
    private func eventually(_ predicate: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }
}
