import Foundation
import Testing
@testable import TrayletApp
import TrayletCore

@Suite("Translation flow") @MainActor
struct TranslationFlowTests {
    @Test func oldOutputIsMarkedAfterInputChangesButClearsIndependently() {
        let flow = TranslationFlow()
        flow.input = "Hello"
        let work = flow.begin(engine: .system)!
        flow.complete(work, text: "你好")
        #expect(flow.outputIsCurrent)
        flow.input = "New source"
        #expect(!flow.outputIsCurrent)
        #expect(flow.output == "你好")
        flow.clearOutput()
        #expect(flow.input == "New source")
        #expect(flow.output.isEmpty)
    }
    @Test func recognitionNeverSubmitsAndLateRecognitionCannotReplaceEdits() {
        let flow = TranslationFlow()
        let first = flow.beginRecognition()
        flow.input = "Typed while recognizing"
        flow.finishRecognition(first, text: "stale OCR")
        #expect(flow.input == "Typed while recognizing")
        let second = flow.beginRecognition()
        flow.finishRecognition(second, text: "Recognized")
        #expect(flow.input == "Recognized")
        #expect(flow.active == nil)
        #expect(flow.phase == .idle)
    }
    @Test func cancelledOrSupersededRequestCannotOverwriteNewResult() {
        let flow = TranslationFlow(); flow.input = "Hello"
        let first = flow.begin(engine: .system)!
        let next = flow.begin(engine: .ai)!
        flow.complete(next, text: "new")
        flow.complete(first, text: "stale")
        #expect(flow.output == "new")
        let third = flow.begin(engine: .system)!
        flow.cancel(); flow.complete(third, text: "cancelled")
        #expect(flow.output == "new")
    }
    @Test func invalidInputsDoNotCreateRequests() {
        let flow = TranslationFlow()
        #expect(flow.begin(engine: .system) == nil)
        flow.input = String(repeating: "x", count: 131073)
        #expect(flow.begin(engine: .ai) == nil)
        flow.input = "Hello"; flow.source = "en"; flow.target = "en"
        #expect(flow.begin(engine: .system) == nil)
    }
    @Test func changingInputRejectsLateResult() {
        let flow = TranslationFlow()
        flow.input = "First"
        let request = flow.begin(engine: .system)!
        flow.input = "Second"
        flow.complete(request, text: "Old translation")
        #expect(flow.output.isEmpty)
        #expect(flow.phase == .idle)
    }
}
