import Foundation
import Combine
import NaturalLanguage
import TrayletCore

struct TranslationWork: Equatable, Sendable, Identifiable {
    let id: UUID
    let text: String
    let source: String
    let target: String
    let engine: TranslationEngineChoice
}

enum TranslationFlowPhase: Equatable { case idle, recognizing, awaitingConfirmation, translating, resourceRequired, failed(String) }

/// The input revision is the ownership of every asynchronous result, including OCR.
@MainActor final class TranslationFlow: ObservableObject {
    @Published var input = "" { didSet { if input != oldValue { cancel(); refreshDetection() } } }
    @Published var source = "auto" { didSet { if source != oldValue { cancel(); refreshDetection() } } }
    /// Language recognized in the source text while the source language is "auto"; shown beside the source box icons.
    @Published private(set) var detectedLanguage: String?
    @Published var target = "zh-Hans" { didSet { if target != oldValue { cancel() } } }
    @Published private(set) var output = ""
    @Published private(set) var phase: TranslationFlowPhase = .idle
    @Published private(set) var active: TranslationWork?
    private var recognitionID: UUID?
    /// The text sample the current detection came from; typing past it does not run recognition again.
    private var detectionSample: String?
    private var outputWork: TranslationWork?
    var outputIsCurrent: Bool { outputWork.map { $0.text == input && $0.source == source && $0.target == target } ?? false }

    func begin(engine: TranslationEngineChoice) -> TranslationWork? {
        cancel()
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard input.utf8.count <= 128 * 1024 else { phase = .failed("原文过长，请缩短后重试。"); return nil }
        guard source != target else { phase = .failed("请选择不同的源语言和目标语言。"); return nil }
        let work = TranslationWork(id: UUID(), text: input, source: source, target: target, engine: engine)
        active = work
        // Every engine that sends text off the Mac waits for an explicit send confirmation.
        phase = engine != .system ? .awaitingConfirmation : .translating
        return work
    }
    /// A newly recognized language that equals the target switches the target: Chinese text goes to English, English to Chinese.
    private func refreshDetection() {
        let sample = source == "auto" ? TranslationLanguageDetector.sample(input) : nil
        guard sample != detectionSample else { return }
        detectionSample = sample
        let detected = sample.flatMap(TranslationLanguageDetector.detect(sample:))
        guard detected != detectedLanguage else { return }
        detectedLanguage = detected
        if let detected, let replacement = TranslationLanguageDetector.target(whenDetected: detected, current: target) { target = replacement }
    }
    func isCurrent(_ work: TranslationWork) -> Bool { active == work }
    func startConfirmed(_ work: TranslationWork) { if isCurrent(work) { phase = .translating } }
    func complete(_ work: TranslationWork, text: String) {
        guard isCurrent(work) else { return }
        outputWork = work; output = text; active = nil; phase = .idle
    }
    func fail(_ work: TranslationWork, message: String) {
        guard isCurrent(work) else { return }
        active = nil; phase = .failed(message)
    }
    func requireResource(_ work: TranslationWork) { if isCurrent(work) { phase = .resourceRequired } }
    func clearOutput() { cancel(); outputWork = nil; output = "" }
    func markOutputStale() { outputWork = nil; objectWillChange.send() }
    /// Called on every keystroke, so it only publishes when there was something to cancel.
    func cancel() {
        recognitionID = nil
        if active != nil { active = nil }
        if phase != .idle { phase = .idle }
    }
    func beginRecognition() -> UUID {
        cancel(); let id = UUID(); recognitionID = id; phase = .recognizing; return id
    }
    func finishRecognition(_ id: UUID, text: String) {
        guard recognitionID == id else { return }
        guard text.utf8.count <= 128 * 1024 else { failRecognition(id, tooLong: true); return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            recognitionID = nil
            phase = .failed("未识别到文字，请重新截图或直接输入。")
            return
        }
        input = text; recognitionID = nil
        phase = .idle
    }
    func failRecognition(_ id: UUID, tooLong: Bool = false) {
        guard recognitionID == id else { return }
        recognitionID = nil
        phase = .failed(tooLong ? "识别文字过长，请缩小图片区域或直接输入。" : "本机文字识别失败，请重新截图或直接输入。")
    }
    func swapLanguages() {
        guard source != "auto" else { return }
        let old = source; source = target; target = old
        if !output.isEmpty { let prior = input; input = output; output = prior }
    }
}

enum TranslationLanguageDetector {
    static let supported: Set<String> = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "it", "pt", "ru", "ar", "hi", "vi", "th", "id", "tr", "pl", "uk", "nl"]
    /// The leading text recognition looks at; nil when there is nothing to recognize.
    static func sample(_ text: String) -> String? {
        let trimmed = String(text.prefix(1200)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(1000))
    }
    static func detect(sample: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.5, supported.contains(best.key.rawValue) else { return nil }
        return best.key.rawValue
    }
    static func isChinese(_ code: String) -> Bool { code.hasPrefix("zh") }
    /// The replacement target when the detected language matches it; nil when the target already differs.
    static func target(whenDetected detected: String, current: String) -> String? {
        guard detected == current || (isChinese(detected) && isChinese(current)) else { return nil }
        return detected == "en" ? "zh-Hans" : "en"
    }
}
