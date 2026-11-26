import AppKit
import Testing
import TrayletCore
@testable import TrayletApp

@MainActor struct SelectionPrecisionTests {
    @Test func arrowsUseOutputPixelsAcrossDisplayScales() {
        for image in [CGSize(width: 100, height: 100), CGSize(width: 200, height: 200), CGSize(width: 250, height: 300)] {
            var document = EditingDocument(canvas: CGSize(width: 100, height: 100))
            document.select(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 80))
            let adjustment1 = document.nudgeSelection(.right, imageSize: image)
            #expect(adjustment1)
            #expect(abs((document.selection!.minX - 20) * image.width / 100 - 1) < 0.000001)
            let adjustment2 = document.nudgeSelection(.up, imageSize: image, accelerated: true)
            #expect(adjustment2)
            #expect(abs((20 - document.selection!.minY) * image.height / 100 - 10) < 0.000001)
            #expect(document.selection!.width == 60 && document.selection!.height == 60)
        }
    }
    @Test func commandResizesFromTheSameOriginAndKeepsMinimumAndBounds() {
        var document = EditingDocument(canvas: CGSize(width: 100, height: 100))
        document.select(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 80))
        document.append(EditingMark(tool: .rectangle, points: [.zero, CGPoint(x: 10, y: 10)]))
        let adjustment3 = document.nudgeSelection(.right, imageSize: CGSize(width: 200, height: 200), resizing: true)
        #expect(adjustment3)
        #expect(document.selection == CGRect(x: 20, y: 20, width: 60.5, height: 60))
        let adjustment4 = document.nudgeSelection(.down, imageSize: CGSize(width: 200, height: 200), accelerated: true, resizing: true)
        #expect(adjustment4)
        #expect(document.selection == CGRect(x: 20, y: 20, width: 60.5, height: 65))
        for _ in 0..<30 { _ = document.nudgeSelection(.right, imageSize: CGSize(width: 200, height: 200), accelerated: true, resizing: true) }
        #expect(document.selection!.maxX == 100)
        for _ in 0..<30 { _ = document.nudgeSelection(.left, imageSize: CGSize(width: 200, height: 200), accelerated: true, resizing: true) }
        #expect(document.selection!.width == 0.5)
        #expect(document.marks.count == 1 && document.marks[0].points[0] == .zero)
    }
    @Test func repeatedNudgesKeepExportDimensionsStableAtFractionalScale() throws {
        let context = try #require(CGContext(data: nil, width: 250, height: 300, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        var document = EditingDocument(canvas: CGSize(width: 100, height: 100), imageSize: CGSize(width:250,height:300))
        document.select(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 80))
        for step in 1...20 {
            document.nudgeSelection(.right, imageSize: CGSize(width: 250, height: 300))
            document.nudgeSelection(.down, imageSize: CGSize(width: 250, height: 300))
            let output = try EditingRenderer.compose(image, document: document)
            #expect(output.width == 150 && output.height == 180, "Pixel dimensions after \(step) moves: \(output.width)×\(output.height)")
        }
        // Real fractional edges still round outward; only tiny arithmetic errors are stabilized.
        document.select(from: CGPoint(x: 20.25, y: 20.25), to: CGPoint(x: 80.25, y: 80.25))
        let fractional = try EditingRenderer.compose(image, document: document)
        #expect(fractional.width == 151 && fractional.height == 181)
    }

    @Test func blockedOrInvalidNudgesDoNotInvalidateRendering() {
        var document = EditingDocument(canvas: CGSize(width: 100, height: 100))
        let adjustment5 = document.nudgeSelection(.right, imageSize: CGSize(width: 200, height: 200))
        #expect(!adjustment5)
        document.select(from: .zero, to: CGPoint(x: 60, y: 60))
        let version = document.renderVersion
        let adjustment6 = document.nudgeSelection(.left, imageSize: CGSize(width: 200, height: 200))
        #expect(!adjustment6)
        let adjustment7 = document.nudgeSelection(.up, imageSize: .zero)
        #expect(!adjustment7)
        #expect(document.renderVersion == version)
    }
}

extension SelectionPrecisionTests {
    @Test func nativeArrowEventsPreserveTextNavigationAndProducePixelSizedExports() throws {
        _ = NSApplication.shared
        let session = EditingSession(image: try EditingTests.fixture(), canvas: CGSize(width: 500, height: 400), fullScreen: false, writer: PrecisionWriter())
        session.document.select(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250))
        let canvas = EditingCanvasView(session: session, selectingForTranslation: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.contentView = nil; window.close() }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: code == 126 ? "\u{f700}" : "\u{f703}",
                charactersIgnoringModifiers: code == 126 ? "\u{f700}" : "\u{f703}", isARepeat: false, keyCode: code))
        }
        canvas.keyDown(with: try key(124))
        canvas.keyDown(with: try key(126, [.shift]))
        canvas.keyDown(with: try key(124, [.command]))
        #expect(session.document.selection == CGRect(x: 52.5, y: 25, width: 302.5, height: 200))
        let output = try session.composite()
        #expect(output.width == 121 && output.height == 80)
        let beforeText = session.document.selection
        session.tool = .text
        let point = canvas.convert(CGPoint(x: 100, y: 100), to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: click)
        let text = try #require(window.firstResponder as? NSTextView)
        text.string = "abc"; text.setSelectedRange(NSRange(location: 1, length: 0))
        text.keyDown(with: try key(124))
        #expect(text.selectedRange().location == 2)
        #expect(session.document.selection == beforeText && !window.isVisible)
    }
}

@MainActor private final class PrecisionWriter: ImageOutputWriting {
    func copyImage(_ image: RasterImage) -> CopyOutcome { .failed }
}
