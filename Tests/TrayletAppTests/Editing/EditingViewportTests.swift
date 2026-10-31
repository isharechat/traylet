import AppKit
import Testing
import TrayletCore
@testable import TrayletApp

@MainActor struct EditingViewportTests {
    @Test func fitCentersSelectionAndResetRestoresOriginalCanvasPoints() {
        var view = EditingViewport()
        let canvas = CGSize(width: 1000, height: 800)
        view.fit(CGRect(x: 100, y: 100, width: 200, height: 100), in: CGRect(x: 20, y: 20, width: 800, height: 400), canvas: canvas)
        #expect(view.scale == 4)
        #expect(view.viewPoint(CGPoint(x: 200, y: 150)) == CGPoint(x: 420, y: 220))
        #expect(view.canvasPoint(CGPoint(x: 420, y: 220)) == CGPoint(x: 200, y: 150))
        view.reset()
        #expect(view.scale == 1 && view.offset == .zero)
        #expect(view.canvasPoint(CGPoint(x: 420, y: 220)) == CGPoint(x: 420, y: 220))
    }

    @Test func nativeFitPanResetPreserveDocumentHistoryAndOutput() throws {
        let fixture = try ViewportFixture()
        defer { fixture.close() }
        let session = fixture.session, canvas = fixture.canvas
        session.document.append(EditingMark(tool: .rectangle, points: [.zero, CGPoint(x: 30, y: 20)]))
        session.document.undo()
        let version = session.document.renderVersion, selection = session.document.selection
        let output = try session.composite()
        canvas.keyDown(with: fixture.key("2", code: 19, flags: .command))
        #expect(session.viewport.scale > 1)
        let fitted = session.viewport
        canvas.keyDown(with: fixture.key("2", code: 19, flags: .command))
        #expect(session.viewport == fitted)
        canvas.keyDown(with: fixture.key(" ", code: 49))
        canvas.mouseDown(with: fixture.mouse(.leftMouseDown, CGPoint(x: 250, y: 180)))
        canvas.mouseDragged(with: fixture.mouse(.leftMouseDragged, CGPoint(x: 275, y: 200)))
        canvas.mouseUp(with: fixture.mouse(.leftMouseUp, CGPoint(x: 275, y: 200)))
        canvas.keyUp(with: fixture.key(" ", code: 49, type: .keyUp))
        #expect(session.viewport.offset == CGPoint(x: fitted.offset.x + 25, y: fitted.offset.y + 20))
        #expect(session.document.selection == selection && session.document.renderVersion == version)
        #expect(session.document.marks.isEmpty && session.document.canRedo)
        #expect(try session.composite() == output)
        canvas.keyDown(with: fixture.key("0", code: 29, flags: .command))
        #expect(session.viewport == EditingViewport())
        #expect(!fixture.window.isVisible)
    }

    @Test func fitLimitsInvalidInputsAndPanKeepImageReachable() {
        var view = EditingViewport()
        let size = CGSize(width: 1000, height: 800), bounds = CGRect(x: 0, y: 0, width: 600, height: 480)
        view.fit(CGRect(x: 30, y: 40, width: 1, height: 1), in: bounds, canvas: size)
        #expect(view.scale == 8)
        #expect(view.viewPoint(CGPoint(x: 30.5, y: 40.5)) == CGPoint(x: 300, y: 240))
        for point in [CGPoint.zero, CGPoint(x: 17.25, y: 18.75), CGPoint(x: 1000, y: 800)] {
            #expect(view.canvasPoint(view.viewPoint(point)) == point)
        }
        view.pan(by: CGSize(width: 1_000_000, height: -1_000_000), in: bounds, canvas: size)
        #expect(view.offset == CGPoint(x: 536, y: -6336))
        #expect(view.viewRect(CGRect(origin: .zero, size: size)).intersection(bounds).size == CGSize(width: 64, height: 64))
        view.fit(CGRect(x: 0, y: 0, width: 1000, height: 800), in: CGRect(x: 0, y: 0, width: 10, height: 10), canvas: size)
        #expect(view.scale == 0.25)
        let before = view
        view.fit(.zero, in: bounds, canvas: size)
        view.pan(by: CGSize(width: CGFloat.infinity, height: 1), in: bounds, canvas: size)
        #expect(view == before)
        view.reset(); view.reset()
        #expect(view == EditingViewport())
    }

    @Test func zoomedDrawingTinyRedactionBlurTextAndUndoMatchOriginalCoordinates() throws {
        let context = try #require(CGContext(data:nil,width:200,height:160,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x:0,y:0,width:200,height:160))
        context.setFillColor(NSColor.black.cgColor); context.fill(CGRect(x:60,y:0,width:140,height:160))
        let source = try EditingRenderer.encode(#require(context.makeImage()))
        let fixture = try ViewportFixture(image:source)
        defer { fixture.close() }
        let session = fixture.session, canvas = fixture.canvas
        canvas.keyDown(with: fixture.key("2", code: 19, flags: .command))
        session.viewport.pan(by: CGSize(width: 12, height: 8), in: canvas.bounds, canvas: session.document.canvas)
        let selection = try #require(session.document.selection)
        let initial = try session.composite()
        for tool in [EditingTool.rectangle, .ellipse, .line, .arrow, .pencil, .blur, .redaction] {
            session.tool = tool
            let first = CGPoint(x: 160.25, y: 160.25)
            let last = tool == .redaction ? CGPoint(x: 160.75, y: 160.75) : CGPoint(x: 205, y: 190)
            canvas.mouseDown(with: fixture.mouse(.leftMouseDown, session.viewport.viewPoint(first)))
            canvas.mouseDragged(with: fixture.mouse(.leftMouseDragged, session.viewport.viewPoint(last)))
            canvas.mouseUp(with: fixture.mouse(.leftMouseUp, session.viewport.viewPoint(last)))
            let mark = try #require(session.document.marks.last)
            #expect(mark.tool == tool)
            #expect(abs(mark.points.first!.x - 61.25) < 0.00001 && abs(mark.points.first!.y - 61.25) < 0.00001)
            let output = try session.composite()
            #expect(output != initial)
            if tool == .redaction {
                let bitmap = try #require(NSBitmapImageRep(data: output.pngData))
                // Canvas x160.25..160.75 maps to source x53.41..53.58, crop starts at x33.
                let pixel = try #require(bitmap.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
                #expect(pixel.redComponent == 0 && pixel.greenComponent == 0 && pixel.blueComponent == 0 && pixel.alphaComponent == 1)
            }
            canvas.keyDown(with: fixture.key("z", code: 6, flags: .command))
            #expect(try session.composite() == initial)
            canvas.keyDown(with: fixture.key("z", code: 6, flags: [.command, .shift]))
            #expect(try session.composite() == output)
            session.document.undo()
        }
        session.tool = .text
        canvas.mouseDown(with: fixture.mouse(.leftMouseDown, session.viewport.viewPoint(CGPoint(x: 150, y: 150))))
        let text = try #require(fixture.window.firstResponder as? NSTextView)
        #expect(abs(text.bounds.width - 150) < 0.00001)
        #expect(abs(text.frame.width - 150 * session.viewport.scale) < 0.00001)
        text.string = "A B"; #expect(canvas.finishText())
        #expect(session.document.marks.last?.points == [CGPoint(x: 51, y: 51)])
        let withText = try session.composite()
        session.viewport.reset()
        #expect(try session.composite() == withText)
        #expect(session.document.selection == selection)
        session.document.undo(); #expect(try session.composite() == initial)
    }

    @Test func zoomedHandlesHaveNineViewPointToleranceAndCropUsesInverseMapping() throws {
        let fixture = try ViewportFixture()
        defer { fixture.close() }
        let session = fixture.session, canvas = fixture.canvas
        canvas.keyDown(with: fixture.key("2", code: 19, flags: .command))
        let corner = session.viewport.viewPoint(CGPoint(x: 300, y: 252))
        session.tool = .rectangle
        #expect(canvas.cursor(at: CGPoint(x: corner.x - 8, y: corner.y)) != .crosshair)
        #expect(canvas.cursor(at: CGPoint(x: corner.x - 10, y: corner.y - 10)) == .crosshair)
        canvas.mouseDown(with: fixture.mouse(.leftMouseDown, corner))
        canvas.mouseDragged(with: fixture.mouse(.leftMouseDragged, session.viewport.viewPoint(CGPoint(x: 321, y: 270))))
        canvas.mouseUp(with: fixture.mouse(.leftMouseUp, session.viewport.viewPoint(CGPoint(x: 321, y: 270))))
        #expect(session.document.selection == CGRect(x: 99, y: 99, width: 222, height: 171))
        let output = try session.composite()
        #expect(output.width == 74 && output.height == 57)
        session.document.selectLive(from: .zero, to: CGPoint(x: 200, y: 200))
        session.viewport.reset()
        session.viewport.pan(by: CGSize(width: 200, height: 200), in: canvas.bounds, canvas: session.document.canvas)
        canvas.mouseDown(with: fixture.mouse(.leftMouseDown, CGPoint(x: 192, y: 200)))
        canvas.mouseDragged(with: fixture.mouse(.leftMouseDragged, CGPoint(x: 220, y: 220)))
        canvas.mouseUp(with: fixture.mouse(.leftMouseUp, CGPoint(x: 220, y: 220)))
        #expect(session.document.selection == CGRect(x: 27, y: 18, width: 174, height: 183))
    }

    @Test func textIMEAndFocusLossDoNotLeaveSpacePanOrStealShortcuts() throws {
        let fixture = try ViewportFixture()
        defer { fixture.close() }
        let session = fixture.session, canvas = fixture.canvas
        canvas.keyDown(with: fixture.key("2", code: 19, flags: .command))
        let fitted = session.viewport
        session.tool = .text
        canvas.mouseDown(with: fixture.mouse(.leftMouseDown, fitted.viewPoint(CGPoint(x: 150, y: 150))))
        let text = try #require(fixture.window.firstResponder as? NSTextView)
        text.string = "AB"; text.setSelectedRange(NSRange(location: 1, length: 0))
        text.keyDown(with: fixture.key(" ", code: 49))
        #expect(text.string == "A B")
        #expect(!canvas.performKeyEquivalent(with: fixture.key("0", code: 29, flags: .command)))
        text.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.keyDown(with: fixture.key("2", code: 19, flags: .command))
        canvas.keyDown(with: fixture.key(" ", code: 49))
        #expect(session.viewport == fitted && !canvas.finishText())
        text.unmarkText(); text.string = "A B"; #expect(canvas.finishText())
        for loss in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            canvas.keyDown(with: fixture.key(" ", code: 49))
            canvas.mouseDown(with: fixture.mouse(.leftMouseDown, CGPoint(x: 250, y: 180)))
            NotificationCenter.default.post(name: loss, object: loss == NSWindow.didResignKeyNotification ? fixture.window : NSApp)
            canvas.mouseDragged(with: fixture.mouse(.leftMouseDragged, CGPoint(x: 275, y: 200)))
            #expect(session.viewport == fitted)
            #expect(canvas.cursor(at: fitted.viewPoint(CGPoint(x: 180, y: 180))) == .iBeam)
        }
        var cancellations = 0; canvas.onCancel = { cancellations += 1 }
        canvas.keyDown(with: fixture.key(" ", code: 49))
        canvas.keyDown(with: fixture.key("", code: 53))
        #expect(cancellations == 1)
        #expect(canvas.cursor(at: fitted.viewPoint(CGPoint(x: 180, y: 180))) == .iBeam)
    }

    @Test func translationViewportNeverSubmitsAndBlankCanvasDoesNotCreateMarks() throws {
        let fixture = try ViewportFixture(translation: true)
        defer { fixture.close() }
        let canvas = fixture.canvas
        var translated = 0; canvas.onTranslate = { translated += 1 }
        canvas.keyDown(with: fixture.key("2", code: 19, flags: .command))
        canvas.keyDown(with: fixture.key(" ", code: 49))
        canvas.mouseDown(with: fixture.mouse(.leftMouseDown, CGPoint(x: 250, y: 180)))
        canvas.mouseDragged(with: fixture.mouse(.leftMouseDragged, CGPoint(x: 275, y: 200)))
        canvas.keyUp(with: fixture.key(" ", code: 49, type: .keyUp))
        canvas.mouseUp(with: fixture.mouse(.leftMouseUp, CGPoint(x: 275, y: 200)))
        canvas.keyDown(with: fixture.key("0", code: 29, flags: .command))
        #expect(translated == 0)
        let drawing = try ViewportFixture()
        defer { drawing.close() }
        drawing.session.document.selectLive(from: .zero, to: CGPoint(x: 200, y: 200))
        drawing.session.tool = .blur
        drawing.session.viewport.pan(by: CGSize(width: 200, height: 200), in: drawing.canvas.bounds, canvas: drawing.session.document.canvas)
        drawing.canvas.mouseDown(with: drawing.mouse(.leftMouseDown, CGPoint(x: 50, y: 50)))
        drawing.canvas.mouseUp(with: drawing.mouse(.leftMouseUp, CGPoint(x: 50, y: 50)))
        #expect(drawing.session.document.marks.isEmpty)
    }

    @Test func hiddenZoomGalleryKeepsToolbarAndControlsInView() async throws {
        _ = NSApplication.shared
        let language = V2Localization.shared.languageCode
        let glass = V2AppearanceState.shared.glassEnabled
        V2AppearanceState.shared.glassEnabled = false
        defer { V2Localization.shared.languageCode = language; V2AppearanceState.shared.glassEnabled = glass }
        let source = try EditingTests.showcaseImage()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-editor-zoom-evidence", isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for width in [180, 320, 900] {
            let size = CGSize(width:width,height:600)
            let session = EditingSession(image:source,canvas:size,fullScreen:false,writer:ViewportWriter())
            let selectedWidth = min(400,max(60,width-120))
            session.document.select(from:CGPoint(x:20,y:70),to:CGPoint(x:20+selectedWidth,y:270))
            session.document.append(EditingMark(tool:.redaction,points:[CGPoint(x:20,y:70),CGPoint(x:55,y:110)]))
            session.document.append(EditingMark(tool:.arrow,points:[CGPoint(x:20,y:130),CGPoint(x:60,y:170)],style:EditingStyle(color:.systemRed,width:3)))
            let canvas = EditingCanvasView(session:session,selectingForTranslation:false)
            let window = NSWindow(contentRect:canvas.bounds,styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; window.contentView = canvas; window.makeFirstResponder(canvas)
            defer { window.contentView = nil; window.close() }
            canvas.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"2",charactersIgnoringModifiers:"2",isARepeat:false,keyCode:19)!)
            for (name,appearance,locale) in [("light",NSAppearance.Name.aqua,"zh-Hans"),("dark",NSAppearance.Name.darkAqua,"en")] {
                V2Localization.shared.languageCode = locale
                window.appearance = NSAppearance(named:appearance)
                await Task.yield()
                canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded()
                let toolbar = try #require(canvas.subviews.first)
                #expect(toolbar.intrinsicContentSize.width <= toolbar.frame.width + 1)
                #expect(canvas.bounds.contains(toolbar.frame) && toolbar.frame.height == 36)
                let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds))
                canvas.cacheDisplay(in:canvas.bounds,to:bitmap)
                try #require(bitmap.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent("zoom-\(width)-\(name).png"))
            }
            if width == 900 {
                session.tool = .text; window.appearance = NSAppearance(named:.aqua)
                let point = session.viewport.viewPoint(CGPoint(x:100,y:220))
                canvas.mouseDown(with:NSEvent.mouseEvent(with:.leftMouseDown,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:0,
                    windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!)
                let text = try #require(window.firstResponder as? NSTextView)
                text.string = "View only · 原图像素不变"
                await Task.yield()
                canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded()
                let options = try #require(canvas.subviews.compactMap { $0 as? EditingBarHost<EditingOptions> }.first)
                // Resolve the hidden SwiftUI host before asking its parent to place the options.
                options.layoutSubtreeIfNeeded()
                let intrinsicWidth = options.intrinsicContentSize.width
                canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded()
                #expect(intrinsicWidth <= options.frame.width + 1)
                #expect(canvas.bounds.contains(options.frame))
                #expect(options.frame.minX == canvas.barFrames.toolbar.minX)
                let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds))
                canvas.cacheDisplay(in:canvas.bounds,to:bitmap)
                try #require(bitmap.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent("zoom-900-text.png"))
                #expect(canvas.finishText())
            }
            #expect(!window.isVisible)
        }
    }
}

@MainActor private final class ViewportFixture {
    let session: EditingSession
    let canvas: EditingCanvasView
    let window: NSWindow
    init(translation: Bool = false, image: RasterImage? = nil) throws {
        _ = NSApplication.shared
        session = EditingSession(image: try image ?? EditingTests.fixture(), canvas: CGSize(width: 600, height: 480), fullScreen: false, writer: ViewportWriter())
        session.document.select(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        canvas = EditingCanvasView(session: session, selectingForTranslation: translation)
        window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas; window.makeFirstResponder(canvas)
    }
    func close() { window.contentView = nil; window.close() }
    func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}

@MainActor private final class ViewportWriter: ImageOutputWriting {
    func copyImage(_ image: RasterImage) -> CopyOutcome { .failed }
}
