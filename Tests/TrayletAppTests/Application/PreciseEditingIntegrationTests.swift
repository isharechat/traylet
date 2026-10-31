import AppKit
import Testing
import TrayletCore
@testable import TrayletApp

@Suite("Precise Editing Integration") @MainActor struct PreciseEditingIntegrationTests {
    @Test func aOnePixelImportedImageSurvivesCopyFailureAndClosesOnlyOnSuccessfulRetry() throws {
        _ = NSApplication.shared
        let larger = try EditingTests.fixture()
        let pixel = try #require(EditingRenderer.decode(larger)?.cropping(to: CGRect(x: 5, y: 5, width: 1, height: 1)))
        let original = try EditingRenderer.encode(pixel)
        let writer = PreciseIntegrationWriter(); writer.result = .failed
        var view: EditingCanvasView?, hidden: NSPanel?
        var completed = 0
        let controller = CaptureEditorController(writer: writer, presentPanel: { window, content in hidden = window; view = content as? EditingCanvasView })
        defer { controller.cancel() }
        controller.onComplete = { completed += 1 }
        #expect(controller.presentImported(image: original, decoded: pixel, availableFrame: CGRect(x: -800, y: -300, width: 800, height: 600)))
        let canvas = try #require(view), panel = try #require(hidden)
        let copy = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        canvas.keyDown(with: copy)
        #expect(controller.isOpen && completed == 0 && !panel.isVisible)
        #expect(writer.images.count == 1 && writer.images.first?.width == 1 && writer.images.first?.height == 1)
        writer.result = .copied
        canvas.keyDown(with: copy)
        #expect(!controller.isOpen && completed == 1 && !panel.isVisible)
        #expect(writer.images.count == 2 && writer.images[0] == writer.images[1])
        #expect(canvas.session.image == original)
    }
    @Test(arguments: [1, 2])
    func aOnePixelSelectionReachesScreenshotTranslationAtNegativeScreenOrigins(scale: Int) throws {
        _ = NSApplication.shared
        let source = try EditingTests.fixture()
        var view: EditingCanvasView?
        var hidden: NSPanel?
        var translated: [RasterImage] = []
        let controller = CaptureEditorController(writer: PreciseIntegrationWriter(), presentPanel: { panel, content in
            hidden = panel; view = content as? EditingCanvasView
        })
        defer { controller.cancel() }
        controller.onTranslate = { translated.append($0) }
        controller.present(image: source, screenFrame: CGRect(x: -500, y: -300, width: source.width / scale, height: source.height / scale), initiallyFullScreen: false, selectingForTranslation: true)
        let canvas = try #require(view), panel = try #require(hidden)
        #expect(!panel.isVisible)
        let start = CGPoint(x: 20, y: 20)
        let end = CGPoint(x: 20 + 1 / CGFloat(scale), y: 20 + 1 / CGFloat(scale))
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, start))
        canvas.mouseDragged(with: try event(.leftMouseDragged, end))
        canvas.mouseUp(with: try event(.leftMouseUp, end))
        #expect(translated.count == 1)
        let image = try #require(translated.first)
        #expect(image.width == 1 && image.height == 1)
        #expect(!controller.isOpen && !panel.isVisible)
        #expect(source.width == 200 && source.height == 160)
    }
}

@MainActor private final class PreciseIntegrationWriter: ImageOutputWriting {
    var images: [RasterImage] = []
    var result: CopyOutcome = .copied
    func copyImage(_ image: RasterImage) -> CopyOutcome { images.append(image); return result }
}
