import AppKit
import Testing
import TrayletCore
@testable import TrayletApp

@Suite("Selected Annotation Integration") @MainActor struct SelectedAnnotationIntegrationTests {
    @Test func anUnfinishedObjectMoveCannotOpenTheSavePickerOrCopyAndEscapeKeepsTheEditor() throws {
        _ = NSApplication.shared
        for tool in [EditingTool.number, .arrow] {
            let source = try EditingTests.fixture()
            let writer = SelectedAnnotationWriter()
            var view: EditingCanvasView?, hidden: NSPanel?
            var pickerCalls = 0
            var pickerCompletion: ((URL?) -> Void)?
            let controller = CaptureEditorController(writer: writer, chooseSaveDestination: { _, completion in
                pickerCalls += 1; pickerCompletion = completion
            }, presentPanel: { panel, content in
                hidden = panel; view = content as? EditingCanvasView
            })
            defer { controller.cancel() }
            controller.present(image: source, screenFrame: CGRect(x: -400, y: -300, width: 400, height: 320), initiallyFullScreen: true)
            let canvas = try #require(view), panel = try #require(hidden)
            let points = tool == .number ? [CGPoint(x: 100, y: 100)] : [CGPoint(x: 80, y: 100), CGPoint(x: 160, y: 100)]
            canvas.session.tool = tool
            canvas.session.document.append(EditingMark(tool: tool, points: points))
            let original = try #require(canvas.session.document.marks.first)
            func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
                try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code))
            }
            canvas.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 100, y: 100)))
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, CGPoint(x: 108, y: 106)))
            #expect(canvas.session.document.marks.first?.points != points)
            canvas.keyDown(with: try key("s", 1, .command))
            #expect(pickerCalls == 0)
            #expect(controller.isOpen && !panel.isVisible)
            canvas.keyDown(with: try key("c", 8, .command))
            #expect(writer.images.isEmpty && controller.isOpen)
            canvas.keyDown(with: try key("", 53))
            #expect(canvas.session.document.marks.first == original)
            #expect(controller.isOpen)
            // Escape rolls back only the gesture. A subsequent normal save remains available.
            canvas.keyDown(with: try key("s", 1, .command))
            #expect(pickerCalls == 1)
            pickerCompletion?(nil)
            #expect(controller.isOpen && canvas.session.image == source && !panel.isVisible)
        }
    }
}

@MainActor private final class SelectedAnnotationWriter: ImageOutputWriting {
    var images: [RasterImage] = []
    func copyImage(_ image: RasterImage) -> CopyOutcome { images.append(image); return .failed }
}
