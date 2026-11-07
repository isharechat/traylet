import Foundation
import SwiftUI
import Translation
import Vision
import ImageIO
import AVFoundation
import NaturalLanguage
import TrayletCore

enum TranslationResourceState: Sendable { case installed, downloadable, unsupported }
enum TranslationResourceCheckError: Error, Equatable, Sendable {
    case unableToIdentifyLanguage
}
protocol TranslationResourceChecking: Sendable {
    func status(text: String, source: String, target: String) async throws -> TranslationResourceState
}
struct TranslationSystemResources: TranslationResourceChecking {
    func status(text: String, source: String, target: String) async throws -> TranslationResourceState {
        let availability = LanguageAvailability()
        let targetLanguage = Locale.Language(identifier: target)
        let state: LanguageAvailability.Status
        if source == "auto" {
            do {
                state = try await availability.status(for: text, to: targetLanguage)
            } catch TranslationError.unableToIdentifyLanguage {
                guard let resolved = TranslationLanguageDetector.sample(text).flatMap(TranslationLanguageDetector.detectOrInfer) else {
                    throw TranslationResourceCheckError.unableToIdentifyLanguage
                }
                state = await availability.status(from: Locale.Language(identifier: resolved), to: targetLanguage)
            }
        } else {
            state = await availability.status(from: Locale.Language(identifier: source), to: targetLanguage)
        }
        switch state { case .installed: return .installed; case .supported: return .downloadable; default: return .unsupported }
    }
}
protocol TranslationRecognizing: Sendable {
    func recognize(_ image: RasterImage) async throws -> String
    func recognize(_ image: RasterImage, decoded: CGImage) async throws -> String
}
extension TranslationRecognizing {
    func recognize(_ image: RasterImage, decoded: CGImage) async throws -> String {
        try await recognize(image)
    }
}
struct TranslationVisionOCR: TranslationRecognizing {
    /// The synchronous Vision adapter can be replaced with a deterministic processor in tests.
    /// Cancellation stops awaiting callers promptly; it cannot force this processor to return.
    typealias Processor = @Sendable (CGImage, VNRecognizeTextRequest) throws -> String
    private let processor: Processor
    private static let queue = DispatchQueue(label: "Traylet.Translation.Vision", qos: .userInitiated)
    init(processor: @escaping Processor = Self.process) { self.processor = processor }

    func recognize(_ image: RasterImage) async throws -> String {
        try await recognize(input: .encoded(image.pngData))
    }
    func recognize(_ image: RasterImage, decoded: CGImage) async throws -> String {
        try Task.checkCancellation()
        guard decoded.width == image.width, decoded.height == image.height else {
            throw FeatureIssue.invalidInput("图片尺寸不匹配。")
        }
        return try await recognize(input: .decoded(decoded))
    }
    private func recognize(input: Job.Input) async throws -> String {
        try Task.checkCancellation()
        let job = Job(input: input, processor: processor)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.install(continuation)
                // Only the job is captured: cancellation drops queued image data immediately.
                Self.queue.async { autoreleasepool { job.run() } }
            }
        } onCancel: { job.cancel() }
    }
    private static func process(_ image: CGImage, _ request: VNRecognizeTextRequest) throws -> String {
        try VNImageRequestHandler(cgImage: image).perform([request])
        var text = ""
        for observation in (request.results ?? []).sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
            guard let line = observation.topCandidates(1).first?.string else { continue }
            let separator = text.isEmpty ? "" : "\n"
            guard text.utf8.count + separator.utf8.count + line.utf8.count <= 128 * 1_024 else {
                throw FeatureIssue.invalidInput("识别文字过长。")
            }
            text += separator + line
        }
        return text
    }

    /// The lock covers ownership of input, continuation and request, never decode or Vision.
    /// One queue covers all recognizer instances, including old work still finishing after cancel.
    private final class Job: @unchecked Sendable {
        enum Input { case encoded(Data), decoded(CGImage) }
        private let lock = NSLock()
        private var input: Input?
        private var continuation: CheckedContinuation<String, any Error>?
        private var request: VNRecognizeTextRequest?
        private var cancelled = false
        private let processor: Processor
        init(input: Input, processor: @escaping Processor) { self.input = input; self.processor = processor }
        func install(_ continuation: CheckedContinuation<String, any Error>) {
            let wasCancelled = lock.withLock {
                if cancelled { return true }
                self.continuation = continuation
                return false
            }
            if wasCancelled { continuation.resume(throwing: CancellationError()) }
        }
        func cancel() {
            let pending = lock.withLock {
                cancelled = true
                input = nil
                let pending = (continuation, request)
                continuation = nil
                request = nil
                return pending
            }
            pending.0?.resume(throwing: CancellationError())
            // VNRequest.h: cancel tries to abort as soon as possible; it is not a join.
            pending.1?.cancel()
        }
        func run() {
            guard let input = lock.withLock({ let value = self.input; self.input = nil; return value }) else { return }
            do {
                let pixels: CGImage
                switch input {
                case .decoded(let decoded): pixels = decoded
                case .encoded(let data):
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        throw FeatureIssue.invalidInput("无法读取截图。")
                    }
                    pixels = decoded
                }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                let shouldRun = lock.withLock {
                    guard !cancelled else { return false }
                    self.request = request
                    return true
                }
                guard shouldRun else { return }
                let text = try processor(pixels, request)
                guard text.utf8.count <= 128 * 1_024 else { throw FeatureIssue.invalidInput("识别文字过长。") }
                finish(.success(text))
            } catch { finish(.failure(error)) }
        }
        private func finish(_ result: Result<String, any Error>) {
            let continuation = lock.withLock {
                let pending = self.continuation
                self.continuation = nil
                request = nil
                return pending
            }
            continuation?.resume(with: result)
        }
    }
}
@MainActor protocol TranslationSpeaking: AnyObject {
    func speak(_ text: String, language: String) throws
    func stop()
    /// Called on the main actor when an utterance finishes by itself.
    var onFinish: (@MainActor () -> Void)? { get set }
}
@MainActor final class TranslationLocalSpeech: NSObject, TranslationSpeaking, AVSpeechSynthesizerDelegate {
    private var synthesizer: AVSpeechSynthesizer?
    var onFinish: (@MainActor () -> Void)?
    func speak(_ text: String, language: String) throws {
        stop()
        guard !text.isEmpty, text.utf8.count <= 128 * 1024 else { throw FeatureIssue.invalidInput("没有可朗读的正文，或正文过长。") }
        var language = language
        if language == "auto" {
            let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
            language = recognizer.dominantLanguage?.rawValue ?? Locale.current.language.languageCode?.identifier ?? "en"
        }
        let voices = AVSpeechSynthesisVoice.speechVoices()
        guard let voice = voices.first(where: { $0.language == language }) ?? voices.first(where: { $0.language.hasPrefix(String(language.prefix(2))) }) else { throw FeatureIssue.unavailable("当前语言没有可用的本机语音，请在系统设置中检查语音资源。") }
        let synth = AVSpeechSynthesizer(); synthesizer = synth; synth.delegate = self
        let utterance = AVSpeechUtterance(string: text); utterance.voice = voice
        synth.speak(utterance)
    }
    func stop() { synthesizer?.stopSpeaking(at: .immediate); synthesizer = nil }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }
}

/// The framework session exists only inside this view's current translationTask action.
/// Every submission has a fresh view identity. There is no stored session or reusable closure.
struct TranslationSystemTaskHost: View {
    let work: TranslationWork
    let prepare: Bool
    let completed: @MainActor (TranslationWork, String) -> Void
    let failed: @MainActor (TranslationWork) -> Void
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .translationTask(.init(source: work.resolvedSource.map(Locale.Language.init(identifier:)), target: Locale.Language(identifier: work.target)), action: Self.action(work: work, prepare: prepare, completed: completed, failed: failed))
    }
    private nonisolated static func action(work: TranslationWork, prepare: Bool, completed: @escaping @MainActor (TranslationWork, String) -> Void, failed: @escaping @MainActor (TranslationWork) -> Void) -> (TranslationSession) async -> Void {
        { session in
            do {
                try Task.checkCancellation()
                if prepare { try await session.prepareTranslation() }
                try Task.checkCancellation()
                let response = try await session.translate(work.text)
                try Task.checkCancellation()
                await completed(work, response.targetText)
            } catch {
                if !Task.isCancelled { await failed(work) }
            }
        }
    }
}
