import AppKit
import Testing
import TrayletCore
@testable import TrayletApp

@MainActor struct HighlighterTests {
    @Test func highlightTintsWhiteAtFixedOpacityWhileKeepingBlackReadable() throws {
        let tool = try #require(EditingTool(rawValue:"highlight"))
        let source = try EditingTests.fixture()
        let original = source.pngData
        var document = EditingDocument(canvas:CGSize(width:200,height:160),fullScreen:true)
        let unmarked = try EditingRenderer.render(source,document:document)
        document.append(EditingMark(tool:tool,points:[CGPoint(x:20,y:20),CGPoint(x:180,y:140)],
            style:EditingStyle(color:NSColor(deviceRed:1,green:1,blue:0,alpha:0),width:20,filled:false)))
        let output = try EditingRenderer.render(source,document:document)
        let bitmap = try #require(NSBitmapImageRep(data:output.pngData))
        // Read encoded sample values without an additional ColorSync conversion to the current display profile.
        let white = try #require(bitmap.colorAt(x:40,y:40))
        #expect(white.redComponent > 0.99 && white.greenComponent > 0.99)
        #expect(abs(white.blueComponent - 0.65) < 0.01 && white.alphaComponent == 1,
            "Encoded RGBa: \(white.redComponent), \(white.greenComponent), \(white.blueComponent), \(white.alphaComponent)")
        let black = try #require(bitmap.colorAt(x:150,y:40))
        #expect(black.redComponent == 0 && black.greenComponent == 0 && black.blueComponent == 0 && black.alphaComponent == 1)
        let outside = try #require(bitmap.colorAt(x:10,y:40))
        let baseBitmap = try #require(NSBitmapImageRep(data:unmarked.pngData))
        let base = try #require(baseBitmap.colorAt(x:10,y:40))
        #expect(outside.isEqual(base))
        #expect(source.pngData == original)
        document.undo(); #expect(try EditingRenderer.render(source,document:document) == unmarked)
        document.redo(); #expect(try EditingRenderer.render(source,document:document) == output)
    }

    @Test func highlightsStayAboveBlurBelowTextAndBelowFinalOpaqueRedaction() throws {
        let source = try EditingTests.fixture()
        var document = EditingDocument(canvas:CGSize(width:200,height:160),fullScreen:true)
        document.append(EditingMark(tool:.blur,points:[CGPoint(x:100,y:80)],style:EditingStyle(brushSize:60)))
        document.append(EditingMark(tool:.text,points:[CGPoint(x:25,y:25)],style:EditingStyle(color:NSColor(deviceRed:0,green:0,blue:1,alpha:1),fontSize:48),text:"M"))
        let baseline = try #require(NSBitmapImageRep(data:EditingRenderer.render(source,document:document).pngData))
        let highlight = EditingMark(tool:.highlight,points:[.zero,CGPoint(x:200,y:160)],style:EditingStyle(color:NSColor(deviceRed:1,green:1,blue:0,alpha:1)))
        document.append(highlight)
        let tinted = try #require(NSBitmapImageRep(data:EditingRenderer.render(source,document:document).pngData))
        var textPixels = 0, tintedTextPixels = 0
        for y in 25..<85 { for x in 25..<80 {
            let before = try #require(baseline.colorAt(x:x,y:y))
            if before.blueComponent > 0.99 && before.redComponent < 0.01 && before.greenComponent < 0.01 {
                textPixels += 1
                let after = try #require(tinted.colorAt(x:x,y:y))
                if after.blueComponent <= 0.99 || after.redComponent >= 0.01 || after.greenComponent >= 0.01 { tintedTextPixels += 1 }
            }
        } }
        #expect(textPixels > 20)
        #expect(tintedTextPixels == 0)
        let gray = try #require(baseline.colorAt(x:100,y:110))
        let yellowGray = try #require(tinted.colorAt(x:100,y:110))
        #expect(abs(yellowGray.redComponent-gray.redComponent) < 0.01)
        #expect(abs(yellowGray.blueComponent-gray.blueComponent*0.65) < 0.01)
        document.append(EditingMark(tool:.redaction,points:[CGPoint(x:20,y:20),CGPoint(x:80,y:90)]))
        let covered = try #require(NSBitmapImageRep(data:EditingRenderer.render(source,document:document,preview:highlight).pngData))
        let black = try #require(covered.colorAt(x:40,y:40))
        #expect(black.redComponent == 0 && black.greenComponent == 0 && black.blueComponent == 0 && black.alphaComponent == 1)
    }

    @Test func nativeHighlightPreviewPreservesForegroundWithAndWithoutCachedBlur() throws {
        _ = NSApplication.shared
        for blurred in [false,true] {
            let source = try fixture(width:400,height:300)
            let session = EditingSession(image:source,canvas:CGSize(width:400,height:300),fullScreen:true,writer:HighlighterWriter())
            if blurred { session.document.append(EditingMark(tool:.blur,points:[CGPoint(x:200,y:150)])) }
            session.document.append(EditingMark(tool:.rectangle,points:[CGPoint(x:80,y:80),CGPoint(x:160,y:160)],
                style:EditingStyle(color:NSColor(deviceRed:0,green:0,blue:1,alpha:1),filled:true)))
            session.tool = .highlight; session.style.color = NSColor(deviceRed:1,green:1,blue:0,alpha:1)
            let canvas = EditingCanvasView(session:session,selectingForTranslation:false)
            let window = NSWindow(contentRect:canvas.bounds,styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; window.contentView = canvas
            defer { window.contentView = nil; window.close() }
            func pixel() throws -> NSColor {
                let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds))
                canvas.cacheDisplay(in:canvas.bounds,to:bitmap)
                return try #require(bitmap.colorAt(x:bitmap.pixelsWide*120/400,y:bitmap.pixelsHigh*120/300))
            }
            let baseline = try pixel()
            canvas.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:70,y:70),canvas:canvas,window:window))
            canvas.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:170,y:170),canvas:canvas,window:window))
            let preview = try pixel()
            #expect(preview.isEqual(baseline), "Preview must stay below foreground; blur cache = \(blurred)")
            canvas.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:170,y:170),canvas:canvas,window:window))
            let committed = try pixel()
            #expect(committed.isEqual(baseline))
            #expect(session.document.marks.last?.tool == .highlight && !window.isVisible)
        }
    }

    @Test func zoomedNonuniformCropKeepsTinyHighlightsButRejectsZeroAreaAndCancelledGestures() throws {
        _ = NSApplication.shared
        let session = EditingSession(image:try EditingTests.fixture(),canvas:CGSize(width:600,height:400),fullScreen:false,writer:HighlighterWriter())
        session.document.select(from:CGPoint(x:100,y:100),to:CGPoint(x:300,y:250))
        session.viewport.fit(session.document.selection!,in:CGRect(x:24,y:24,width:552,height:272),canvas:session.document.canvas)
        session.viewport.pan(by:CGSize(width:12,height:8),in:CGRect(x:0,y:0,width:600,height:400),canvas:session.document.canvas)
        session.tool = .highlight; session.style.color = NSColor(deviceRed:1,green:1,blue:0,alpha:1)
        let canvas = EditingCanvasView(session:session,selectingForTranslation:false)
        let window = NSWindow(contentRect:canvas.bounds,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.contentView = nil; window.close() }
        let baseline = try session.composite()
        let origin = CGPoint(x:150.25,y:150.25)
        func event(_ type:NSEvent.EventType,_ point:CGPoint) -> NSEvent {
            mouse(type,session.viewport.viewPoint(point),canvas:canvas,window:window)
        }
        for end in [origin,CGPoint(x:170.25,y:150.25),CGPoint(x:150.25,y:170.25)] {
            let version = session.document.renderVersion
            canvas.mouseDown(with:event(.leftMouseDown,origin))
            canvas.mouseDragged(with:event(.leftMouseDragged,end))
            canvas.mouseUp(with:event(.leftMouseUp,end))
            #expect(session.document.marks.isEmpty && session.document.renderVersion == version)
            #expect(try session.composite() == baseline)
            while session.document.canUndo { session.document.undo() }
        }
        let tiny = CGPoint(x:150.75,y:150.75)
        canvas.mouseDown(with:event(.leftMouseDown,origin))
        canvas.mouseDragged(with:event(.leftMouseDragged,tiny))
        canvas.mouseUp(with:event(.leftMouseUp,tiny))
        let mark = try #require(session.document.marks.last)
        #expect(mark.tool == .highlight && abs(mark.points[0].x-51.25) < 0.00001 && abs(mark.points[0].y-50.25) < 0.00001)
        let marked = try session.composite()
        #expect(marked.width == 67 && marked.height == 60 && marked != baseline)
        session.document.undo(); #expect(try session.composite() == baseline)
        session.document.redo(); #expect(try session.composite() == marked)
        let version = session.document.renderVersion, viewport = session.viewport
        for cancel in 0..<3 {
            canvas.mouseDown(with:event(.leftMouseDown,origin))
            canvas.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:200,y:200)))
            if cancel == 0 {
                canvas.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,
                    context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:53)!)
            } else {
                NotificationCenter.default.post(name:cancel == 1 ? NSWindow.didResignKeyNotification : NSApplication.didResignActiveNotification,
                    object:cancel == 1 ? window : NSApp)
            }
            canvas.mouseUp(with:event(.leftMouseUp,CGPoint(x:200,y:200)))
            #expect(session.document.marks.count == 1 && session.document.renderVersion == version && session.viewport == viewport)
            #expect(try session.composite() == marked)
        }
        #expect(!window.isVisible)
    }

    @Test func tenToolsFitNarrowAndThresholdWindowsAndHighlightHasOnlyColorOptions() async throws {
        _ = NSApplication.shared
        #expect(EditingTool.allCases.count == 10 && EditingTool.allCases.contains(.highlight))
        let source = try EditingTests.fixture()
        for width in [180,239,240,539,540,579,580,619,620,900] {
            let session = EditingSession(image:source,canvas:CGSize(width:width,height:400),fullScreen:true,writer:HighlighterWriter())
            session.tool = .highlight
            let canvas = EditingCanvasView(session:session,selectingForTranslation:false)
            let window = NSWindow(contentRect:canvas.bounds,styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; window.contentView = canvas
            defer { window.contentView = nil; window.close() }
            await Task.yield()
            canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded()
            let toolbar = try #require(canvas.subviews.first), options = try #require(canvas.subviews.dropFirst().first)
            #expect(toolbar.intrinsicContentSize.width <= toolbar.frame.width + 1)
            #expect(canvas.bounds.contains(toolbar.frame) && toolbar.frame.height == 36)
            #expect(options.intrinsicContentSize.width <= 180 && options.intrinsicContentSize.width <= options.frame.width + 1)
            #expect(canvas.bounds.contains(options.frame) && options.frame.height == 36 && !options.isHidden)
            func descendants(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let controls = descendants(options)
            #expect(controls.filter { $0 is NSColorWell }.count == 1)
            #expect(!controls.contains { $0 is NSSlider || $0 is NSTextField })
            #expect(!window.isVisible)
        }
    }

    @Test func alphaOverlapAndCropClippingIgnoreUnusedStyleAndDragDirection() throws {
        let transparent = try fixture(width:40,height:40,alpha:0)
        var transparentDocument = EditingDocument(canvas:CGSize(width:40,height:40),fullScreen:true)
        let highlight = EditingMark(tool:.highlight,points:[CGPoint(x:10,y:10),CGPoint(x:30,y:30)],
            style:EditingStyle(color:NSColor(deviceRed:1,green:1,blue:0,alpha:0.8),width:20,filled:false))
        transparentDocument.append(highlight)
        var bitmap = try #require(NSBitmapImageRep(data:EditingRenderer.render(transparent,document:transparentDocument).pngData))
        let single = try #require(bitmap.colorAt(x:20,y:20))
        #expect(abs(single.alphaComponent-0.35) < 0.01 && single.redComponent > 0.99 && single.blueComponent < 0.01)
        #expect(bitmap.colorAt(x:5,y:5)?.alphaComponent == 0)
        transparentDocument.append(highlight)
        bitmap = try #require(NSBitmapImageRep(data:EditingRenderer.render(transparent,document:transparentDocument).pngData))
        #expect(abs(try #require(bitmap.colorAt(x:20,y:20)).alphaComponent-0.5775) < 0.01)

        let white = try fixture(width:120,height:160)
        var cropped = EditingDocument(canvas:CGSize(width:100,height:80))
        cropped.select(from:CGPoint(x:20,y:10),to:CGPoint(x:80,y:70))
        let style = EditingStyle(color:NSColor(deviceRed:1,green:1,blue:0,alpha:0),width:1,filled:true)
        cropped.append(EditingMark(tool:.highlight,points:[CGPoint(x:-10,y:-10),CGPoint(x:10,y:10)],style:style))
        let output = try EditingRenderer.render(white,document:cropped)
        #expect(output.width == 72 && output.height == 120)
        bitmap = try #require(NSBitmapImageRep(data:output.pngData))
        #expect(abs(try #require(bitmap.colorAt(x:6,y:10)).blueComponent-0.65) < 0.01)
        #expect(bitmap.colorAt(x:13,y:10)?.blueComponent == 1 && bitmap.colorAt(x:6,y:21)?.blueComponent == 1)
        cropped.undo()
        cropped.append(EditingMark(tool:.highlight,points:[CGPoint(x:10,y:10),CGPoint(x:-10,y:-10)],
            style:EditingStyle(color:style.color.withAlphaComponent(1),width:20,filled:false)))
        #expect(try EditingRenderer.render(white,document:cropped) == output)
    }

    @Test(.enabled(if:ProcessInfo.processInfo.environment["TRAYLET_HIGHLIGHTER_EVIDENCE_DIR"] != nil))
    func hiddenHighlighterGallery() async throws {
        _ = NSApplication.shared
        let path = try #require(ProcessInfo.processInfo.environment["TRAYLET_HIGHLIGHTER_EVIDENCE_DIR"])
        #expect(path.hasPrefix("/")); guard path.hasPrefix("/") else { return }
        let directory = URL(fileURLWithPath:path,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let language = V2Localization.shared.languageCode, glass = V2AppearanceState.shared.glassEnabled
        V2AppearanceState.shared.glassEnabled = false
        defer { V2Localization.shared.languageCode = language; V2AppearanceState.shared.glassEnabled = glass }
        let source = try EditingTests.showcaseImage()
        for (name,appearance,locale) in [("light",NSAppearance.Name.aqua,"zh-Hans"),("dark",NSAppearance.Name.darkAqua,"en")] {
            V2Localization.shared.languageCode = locale
            let session = EditingSession(image:source,canvas:CGSize(width:1100,height:720),fullScreen:false,writer:HighlighterWriter())
            session.document.select(from:CGPoint(x:110,y:80),to:CGPoint(x:990,y:570))
            session.document.append(EditingMark(tool:.highlight,points:[CGPoint(x:20,y:110),CGPoint(x:860,y:166)],
                style:EditingStyle(color:NSColor(deviceRed:1,green:0.9,blue:0,alpha:1))))
            session.document.append(EditingMark(tool:.text,points:[CGPoint(x:300,y:390)],style:EditingStyle(color:.systemBlue,fontSize:22),text:"Highlight · 原文仍可读"))
            session.document.append(EditingMark(tool:.blur,points:[CGPoint(x:740,y:198),CGPoint(x:820,y:198)],style:EditingStyle(brushSize:36)))
            session.document.append(EditingMark(tool:.redaction,points:[CGPoint(x:740,y:260),CGPoint(x:820,y:290)]))
            session.tool = .highlight; session.style.color = NSColor(deviceRed:1,green:0.9,blue:0,alpha:1)
            let canvas = EditingCanvasView(session:session,selectingForTranslation:false)
            let window = NSWindow(contentRect:canvas.bounds,styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; window.contentView = canvas; window.appearance = NSAppearance(named:appearance)
            defer { window.contentView = nil; window.close() }
            await Task.yield()
            canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded()
            let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds))
            canvas.cacheDisplay(in:canvas.bounds,to:bitmap)
            try #require(bitmap.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent("highlight-\(name).png"))
            #expect(!window.isVisible && canvas.barFrames.toolbar.height == 36)
        }
    }

    private func fixture(width:Int,height:Int,alpha:CGFloat = 1) throws -> RasterImage {
        let context = try #require(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:1,green:1,blue:1,alpha:alpha)); context.fill(CGRect(x:0,y:0,width:width,height:height))
        return try EditingRenderer.encode(#require(context.makeImage()))
    }
    private func mouse(_ type:NSEvent.EventType,_ point:CGPoint,canvas:NSView,window:NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,
            context:nil,eventNumber:0,clickCount:1,pressure:1)!
    }
}

@MainActor private final class HighlighterWriter: ImageOutputWriting {
    func copyImage(_ image:RasterImage) -> CopyOutcome { .failed }
}
