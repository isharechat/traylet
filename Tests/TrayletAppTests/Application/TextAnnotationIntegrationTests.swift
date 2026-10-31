import AppKit
import Testing
import TrayletCore
@testable import TrayletApp

@Suite("Text Annotation Integration") @MainActor struct TextAnnotationIntegrationTests {
    @Test func markedTextBlocksSaveThenCancelledAndFailedSavesKeepOneEditedObject() throws {
        let f = try TextAnnotationHarness(); defer { f.controller.cancel() }
        let (original, text) = try f.edit("Original 原文")
        text.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        f.canvas.onSave?()
        #expect(f.picker.completions.isEmpty && f.controller.isOpen)
        #expect(!f.canvas.session.copy() && f.writer.images.isEmpty)
        #expect(f.canvas.session.document.marks == [original])
        text.unmarkText(); text.string = "  Updated 更新\nsecond line  "
        f.canvas.onSave?()
        #expect(f.picker.completions.count == 1)
        #expect(f.canvas.session.document.marks.count == 1)
        #expect(f.canvas.session.document.marks.first?.id == original.id)
        #expect(f.canvas.session.document.marks.first?.text == "  Updated 更新\nsecond line  ")
        f.picker.completions[0](nil)
        #expect(f.controller.isOpen && !f.panel.isVisible)
        f.canvas.onSave?()
        #expect(f.picker.completions.count == 2)
        let unavailable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("missing/output.png")
        f.picker.completions[1](unavailable)
        #expect(f.controller.isOpen && !f.canvas.session.message.isEmpty)
        #expect(f.canvas.session.document.marks.count == 1 && f.canvas.session.image == f.source)
        let expected = try f.canvas.session.composite()
        f.writer.outcome = .copied
        f.canvas.keyDown(with: try f.key("c", code: 8, flags: .command))
        #expect(f.writer.images == [expected])
        #expect(!f.controller.isOpen && !f.panel.isVisible)
    }

    @Test func closingAndReopeningRejectsRetainedEditorCallbacksWithoutChangingEitherOriginal() throws {
        let f = try TextAnnotationHarness(); defer { f.controller.cancel() }
        let oldCanvas = f.canvas
        let (original, retainedEditor) = try f.edit("Original 原文")
        retainedEditor.string = "Uncommitted 草稿"
        let lateCommit = try f.key("\r", code: 36, flags: .command)
        f.controller.cancel()
        #expect(oldCanvas.session.document.marks == [original])
        #expect(!oldCanvas.session.isEditingText && !f.controller.isOpen)
        f.present()
        let (nextOriginal, nextEditor) = try f.edit("Next 下一个")
        nextEditor.string = "Next draft 新草稿"
        retainedEditor.keyDown(with: lateCommit)
        #expect(oldCanvas.session.document.marks == [original])
        #expect(f.canvas.session.document.marks == [nextOriginal])
        #expect(nextEditor.string == "Next draft 新草稿" && f.canvas.session.isEditingText)
        #expect(f.controller.isOpen && f.writer.images.isEmpty && !f.panel.isVisible)
    }
}

@MainActor private final class TextAnnotationHarness {
    let source: RasterImage
    let controller: CaptureEditorController
    let writer: TextAnnotationWriter
    let picker: TextAnnotationPicker
    private let presentation: TextAnnotationPresentation
    var canvas: EditingCanvasView { presentation.canvas! }
    var panel: NSPanel { presentation.panel! }
    init() throws {
        _ = NSApplication.shared
        source = try EditingTests.fixture()
        let writer = TextAnnotationWriter(), picker = TextAnnotationPicker(), presentation = TextAnnotationPresentation()
        self.writer = writer; self.picker = picker; self.presentation = presentation
        controller = CaptureEditorController(writer: writer, chooseSaveDestination: { _, completion in
            picker.completions.append(completion)
        }, presentPanel: { panel, content in
            presentation.panel = panel; presentation.canvas = content as? EditingCanvasView
        })
        present()
        _ = try #require(presentation.canvas); _ = try #require(presentation.panel)
    }
    func present() {
        controller.present(image: source, screenFrame: CGRect(x: -400, y: -300, width: 400, height: 320), initiallyFullScreen: true)
    }
    func edit(_ value: String) throws -> (EditingMark, NSTextView) {
        canvas.session.tool = .text
        canvas.session.document.append(EditingMark(tool: .text, points: [CGPoint(x: 30, y: 35)], text: value))
        let original = try #require(canvas.session.document.marks.first)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: canvas.convert(CGPoint(x: 40, y: 45), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        canvas.mouseDown(with: event)
        let editor = try #require(panel.firstResponder as? NSTextView)
        #expect(editor.string == value)
        return (original, editor)
    }
    func key(_ value: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: panel.windowNumber,
            context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: code))
    }
}
@MainActor private final class TextAnnotationPresentation { var canvas: EditingCanvasView?; var panel: NSPanel? }
@MainActor private final class TextAnnotationPicker { var completions: [(URL?) -> Void] = [] }
@MainActor private final class TextAnnotationWriter: ImageOutputWriting {
    var outcome: CopyOutcome = .failed
    var images: [RasterImage] = []
    func copyImage(_ image: RasterImage) -> CopyOutcome { images.append(image); return outcome }
}
