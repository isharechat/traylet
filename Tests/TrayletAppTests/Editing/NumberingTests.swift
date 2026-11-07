import AppKit
import Testing
import TrayletCore
@testable import TrayletApp

@MainActor struct NumberingTests {
    @Test func numberToolChangesPixelsAndUndoRedoRestoresOriginalNumber() throws {
        let tool = try #require(EditingTool(rawValue:"number"))
        let source = try EditingTests.fixture()
        var document = EditingDocument(canvas:CGSize(width:200,height:160),fullScreen:true)
        let original = try EditingRenderer.render(source,document:document)
        document.append(EditingMark(tool:tool,points:[CGPoint(x:50,y:50)],style:EditingStyle(color:.systemBlue,fontSize:24)))
        let numbered = try EditingRenderer.render(source,document:document)
        #expect(numbered != original)
        document.undo(); #expect(try EditingRenderer.render(source,document:document) == original)
        document.redo(); #expect(try EditingRenderer.render(source,document:document) == numbered)
        #expect(source.pngData == (try EditingTests.fixture()).pngData)
    }
    @Test func arbitraryDeletionUndoAndBranchingNeverReuseOrRenumber() {
        var d = EditingDocument(canvas:CGSize(width:300,height:240),fullScreen:true)
        for x in [40,100,160] { d.append(EditingMark(tool:.number,points:[CGPoint(x:x,y:60)])) }
        d.append(EditingMark(tool:.line,points:[.zero,CGPoint(x:20,y:20)]))
        d.selectNumber(2); let deleted = d.deleteSelectedMark(); #expect(deleted)
        #expect(d.marks.compactMap(\.number) == [1,3])
        d.undo(); #expect(d.marks.compactMap(\.number) == [1,2,3] && d.marks[1].points == [CGPoint(x:100,y:60)])
        d.redo(); #expect(d.marks.compactMap(\.number) == [1,3])
        d.append(EditingMark(tool:.number,points:[CGPoint(x:100,y:120)]))
        #expect(d.marks.compactMap(\.number) == [1,3,4])
        d.undo(); d.append(EditingMark(tool:.number,points:[CGPoint(x:160,y:120)]))
        #expect(d.marks.compactMap(\.number) == [1,3,5] && !d.canRedo)
        d.selectNumber(99); let missing = d.deleteSelectedMark(); #expect(!missing)
        #expect(d.marks.last?.points == [CGPoint(x:160,y:120)] && d.nextNumber == 6)
        while d.canUndo { d.undo() }
        #expect(d.marks.isEmpty && d.nextNumber == 6)
        while d.canRedo { d.redo() }
        #expect(d.marks.compactMap(\.number) == [1,3,5])
    }

    @Test func hiddenClicksSelectDeleteCancelAndPreserveOutputAfterFailure() throws {
        _ = NSApplication.shared
        let writer = NumberWriter()
        let s = EditingSession(image:try EditingTests.fixture(),canvas:CGSize(width:600,height:480),fullScreen:true,writer:writer)
        s.tool = .number
        let view = EditingCanvasView(session:s,selectingForTranslation:false)
        let window = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        func mouse(_ type:NSEvent.EventType,_ p:CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:view.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,
                context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        func key(_ code:UInt16,_ text:String = "",_ flags:NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,
                context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!
        }
        func click(_ p:CGPoint) { view.mouseDown(with:mouse(.leftMouseDown,p)); view.mouseUp(with:mouse(.leftMouseUp,p)) }
        click(CGPoint(x:100,y:100)); click(CGPoint(x:200,y:100)); click(CGPoint(x:100,y:100))
        #expect(s.document.marks.compactMap(\.number) == [1,2] && s.document.selectedMark?.number == 1)
        view.keyDown(with:key(51)); #expect(s.document.marks.compactMap(\.number) == [2])
        view.keyDown(with:key(6,"z",.command)); #expect(s.document.marks.compactMap(\.number) == [1,2])
        view.keyDown(with:key(6,"z",[.command,.shift])); #expect(s.document.marks.compactMap(\.number) == [2])
        for notification in [NSWindow.didResignKeyNotification,NSApplication.didResignActiveNotification] {
            view.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:300,y:100)))
            NotificationCenter.default.post(name:notification,object:notification == NSWindow.didResignKeyNotification ? window : NSApp)
            view.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:300,y:100)))
            #expect(s.document.nextNumber == 3 && s.document.marks.count == 1)
        }
        view.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:300,y:100)))
        view.keyDown(with:key(53)); view.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:300,y:100)))
        #expect(s.document.nextNumber == 3)
        click(CGPoint(x:300,y:100)); #expect(s.document.marks.last?.number == 3)
        click(CGPoint(x:200,y:100)); s.tool = .rectangle; view.keyDown(with:key(51))
        #expect(s.document.marks.compactMap(\.number) == [2,3] && s.document.selectedMark?.number == nil)
        s.tool = .number; click(CGPoint(x:200,y:100))
        let fieldEditor = NSTextView(frame:CGRect(x:20,y:200,width:80,height:30))
        view.addSubview(fieldEditor); window.makeFirstResponder(fieldEditor)
        fieldEditor.string = "AB"; fieldEditor.setSelectedRange(NSRange(location:1,length:0))
        fieldEditor.keyDown(with:key(51,"\u{7f}")); view.keyDown(with:key(51))
        #expect(fieldEditor.string == "B" && s.document.marks.compactMap(\.number) == [2,3])
        fieldEditor.removeFromSuperview(); window.makeFirstResponder(view)
        view.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:400,y:100))); view.keyDown(with:key(51))
        view.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:420,y:100)))
        view.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:420,y:100)))
        #expect(s.document.marks.compactMap(\.number) == [2,3] && s.document.nextNumber == 4)
        let output = try s.composite()
        #expect(!s.copy() && writer.images.last == output && s.document.marks.count == 2)
        #expect(!s.save(to:nil) && !s.save(to:URL(fileURLWithPath:"/dev/null/number.png")))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        defer { try? FileManager.default.removeItem(at:url) }
        #expect(s.save(to:url)); #expect(try Data(contentsOf:url) == output.pngData)
        writer.outcome = .copied; var closed = 0; view.onCancel = { closed += 1 }
        view.keyDown(with:key(8,"c",.command)); #expect(closed == 1 && writer.images.last == output && !window.isVisible)
    }

    @Test func numberControlsFitAt180PointsAndTenToolThreshold() async throws {
        _ = NSApplication.shared
        let language = V2Localization.shared.languageCode
        defer { V2Localization.shared.languageCode = language }
        var measurements: [[String:Any]] = []
        for locale in ["en","zh-Hans"] {
            V2Localization.shared.languageCode = locale
            for width in [180,239,240,299,300,579,580,619,620,640,900] {
                let s = EditingSession(image:try EditingTests.fixture(),canvas:CGSize(width:width,height:320),fullScreen:true,writer:NumberWriter())
                s.tool = .number
                let view = EditingCanvasView(session:s,selectingForTranslation:false)
                let window = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
                window.isReleasedWhenClosed = false; window.contentView = view
                defer { window.contentView = nil; window.close() }
                await Task.yield(); view.needsLayout = true; view.layoutSubtreeIfNeeded()
                let toolbar = try #require(view.subviews.first), options = try #require(view.subviews.dropFirst().first)
                measurements.append(["locale":locale,"canvasWidth":width,"toolbarIntrinsicWidth":toolbar.intrinsicContentSize.width,
                    "optionsIntrinsicWidth":options.intrinsicContentSize.width,"toolbarFrameWidth":toolbar.frame.width,"optionsFrameWidth":options.frame.width])
                #expect(toolbar.intrinsicContentSize.width <= toolbar.frame.width+1)
                #expect(options.intrinsicContentSize.width <= options.frame.width+1)
                #expect(view.bounds.contains(toolbar.frame) && view.bounds.contains(options.frame))
                func descendants(_ v:NSView) -> [NSView] { [v]+v.subviews.flatMap(descendants) }
                #expect(descendants(options).contains { $0 is NSTextField })
                #expect(descendants(options).contains { $0 is NSColorWell })
                #expect(!window.isVisible)
            }
        }
        if let path = ProcessInfo.processInfo.environment["TRAYLET_PRECISE_EDITING_EVIDENCE_DIR"], path.hasPrefix("/") {
            let directory = URL(fileURLWithPath:path,isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try JSONSerialization.data(withJSONObject:measurements,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("layout-measurements.json"))
        }
    }

    @Test func liveAndExportBadgesShareGeometryAcrossNonuniformViewportAndFinalRedaction() throws {
        _ = NSApplication.shared
        let s = EditingSession(image:try EditingTests.fixture(),canvas:CGSize(width:400,height:240),fullScreen:false,writer:NumberWriter())
        s.document.select(from:CGPoint(x:20,y:15),to:CGPoint(x:380,y:225))
        s.document.append(EditingMark(tool:.number,points:[CGPoint(x:60,y:60)],style:EditingStyle(color:NSColor(deviceRed:1,green:0,blue:0,alpha:1),fontSize:24)))
        s.document.append(EditingMark(tool:.number,points:[CGPoint(x:360,y:210)],style:EditingStyle(color:.systemBlue,fontSize:96)))
        let view = EditingCanvasView(session:s,selectingForTranslation:false)
        let window = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        func live(_ point:CGPoint) throws -> NSColor {
            view.needsDisplay = true
            let template = try #require(view.bitmapImageRepForCachingDisplay(in:view.bounds))
            // Automatic cache reps may inherit a wide-gamut display profile. Keep the synthetic
            // destination in the same Device RGB space as the specified mark and exported pixels.
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:template.pixelsWide,pixelsHigh:template.pixelsHigh,
                bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
            bitmap.size = view.bounds.size
            view.cacheDisplay(in:view.bounds,to:bitmap)
            let p = s.viewport.viewPoint(point)
            let x = Int(p.x*CGFloat(bitmap.pixelsWide)/400), y = Int(p.y*CGFloat(bitmap.pixelsHigh)/240)
            let color = try #require(bitmap.colorAt(x:x,y:y))
            return color
        }
        for zoom in [false,true] {
            if zoom { s.viewport.fit(s.document.selection!,in:CGRect(x:30,y:30,width:300,height:150),canvas:s.document.canvas) }
            let red = try live(CGPoint(x:67,y:75))
            #expect(red.redComponent > 0.9 && red.greenComponent < 0.1)
        }
        var exported = try s.composite()
        #expect(exported.width == 180 && exported.height == 140)
        var bitmap = try #require(NSBitmapImageRep(data:exported.pngData))
        let red = try #require(bitmap.colorAt(x:23,y:40)); #expect(red.redComponent > 0.9 && red.greenComponent < 0.1)
        s.document.append(EditingMark(tool:.redaction,points:[CGPoint(x:35,y:35),CGPoint(x:85,y:85)]))
        s.document.append(EditingMark(tool:.number,points:[CGPoint(x:60,y:60)],style:EditingStyle(color:.white,fontSize:18)))
        s.tool = .number; s.document.selectNumber(3)
        exported = try s.composite(); bitmap = try #require(NSBitmapImageRep(data:exported.pngData))
        for y in 24..<55 { for x in 18..<42 {
            let black = try #require(bitmap.colorAt(x:x,y:y))
            #expect(black.redComponent == 0 && black.greenComponent == 0 && black.blueComponent == 0 && black.alphaComponent == 1)
        } }
        let covered = try live(CGPoint(x:67,y:75))
        #expect(covered.redComponent == 0 && covered.greenComponent == 0 && covered.blueComponent == 0)
        #expect(!window.isVisible)
    }

    @Test func zoomedNumberClicksUseSelectionLocalCoordinatesAndMultidigitBadgesRemainLegible() throws {
        _ = NSApplication.shared
        let s = EditingSession(image:try EditingTests.fixture(),canvas:CGSize(width:400,height:240),fullScreen:false,writer:NumberWriter())
        s.document.select(from:CGPoint(x:20,y:15),to:CGPoint(x:380,y:225)); s.tool = .number
        s.viewport.fit(s.document.selection!,in:CGRect(x:25,y:20,width:330,height:150),canvas:s.document.canvas)
        let view = EditingCanvasView(session:s,selectingForTranslation:false)
        let window = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        let point = s.viewport.viewPoint(CGPoint(x:80,y:75))
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            view.mouseDownOrUpForNumberTest(type,point:point,window:window)
        }
        #expect(s.document.marks.count == 1)
        let first = try #require(s.document.marks.first?.points.first)
        #expect(abs(first.x-60) < 0.00001 && abs(first.y-60) < 0.00001)
        for _ in 2...12 { s.document.append(EditingMark(tool:.number,points:[CGPoint(x:160,y:100)],style:EditingStyle(color:.systemBlue,fontSize:24))) }
        #expect(s.document.marks.last?.number == 12)
        let last = try #require(s.document.marks.last)
        #expect(EditingNumberBadge.bounds(last).width > EditingNumberBadge.bounds(s.document.marks[0]).width)
        let output = try s.composite(); #expect(output.width == 180 && output.height == 140)
        s.document.selectNumber(1); _ = s.document.deleteSelectedMark(); s.document.undo()
        #expect(s.document.marks.first?.number == 1 && s.document.marks.first?.points.first == first)
        #expect(try s.composite() == output && !window.isVisible)
    }

    @Test(.enabled(if:ProcessInfo.processInfo.environment["TRAYLET_PRECISE_EDITING_EVIDENCE_DIR"] != nil))
    func hiddenPreciseAndNumberedGallery() async throws {
        _ = NSApplication.shared
        let path = try #require(ProcessInfo.processInfo.environment["TRAYLET_PRECISE_EDITING_EVIDENCE_DIR"])
        #expect(path.hasPrefix("/")); guard path.hasPrefix("/") else { return }
        let directory = URL(fileURLWithPath:path,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let language = V2Localization.shared.languageCode, glass = V2AppearanceState.shared.glassEnabled
        V2AppearanceState.shared.glassEnabled = false
        defer { V2Localization.shared.languageCode = language; V2AppearanceState.shared.glassEnabled = glass }
        for (name,width,appearance,tiny) in [
            ("numbered-light",900,NSAppearance.Name.aqua,false), ("numbered-dark",900,NSAppearance.Name.darkAqua,false),
            ("numbered-narrow",180,NSAppearance.Name.aqua,false), ("tiny-center",400,NSAppearance.Name.aqua,true),
            ("tiny-corner",400,NSAppearance.Name.darkAqua,true)
        ] {
            V2Localization.shared.languageCode = name == "numbered-light" ? "zh-Hans" : "en"
            let source = tiny ? try EditingTests.fixture() : try EditingTests.showcaseImage()
            let s = EditingSession(image:source,canvas:CGSize(width:CGFloat(width),height:width == 900 ? 900*1440/2200.0 : 320),fullScreen:!tiny,writer:NumberWriter())
            if tiny {
                let origin = name == "tiny-corner" ? CGPoint(x:398,y:318) : CGPoint(x:200,y:140)
                s.document.select(from:origin,to:CGPoint(x:origin.x+2,y:origin.y+2))
            } else {
                s.document.append(EditingMark(tool:.number,points:[CGPoint(x:CGFloat(width)*0.2,y:85)],style:EditingStyle(color:.systemRed,fontSize:24)))
                s.document.append(EditingMark(tool:.number,points:[CGPoint(x:CGFloat(width)*0.5,y:155)],style:EditingStyle(color:.systemBlue,fontSize:32)))
                s.document.append(EditingMark(tool:.number,points:[CGPoint(x:CGFloat(width)*0.75,y:85)],style:EditingStyle(color:.systemYellow,fontSize:24)))
                s.tool = .number
            }
            let view = EditingCanvasView(session:s,selectingForTranslation:false)
            let window = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.appearance = NSAppearance(named:appearance)
            defer { window.contentView = nil; window.close() }
            await Task.yield(); view.needsLayout = true; view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in:view.bounds)); view.cacheDisplay(in:view.bounds,to:bitmap)
            try #require(bitmap.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent(name+".png"))
            if name == "numbered-light" { try s.composite().pngData.write(to:directory.appendingPathComponent("numbered-export.png")) }
            #expect(!window.isVisible)
        }
    }

}

@MainActor private final class NumberWriter: ImageOutputWriting {
    var outcome:CopyOutcome = .failed
    var images:[RasterImage] = []
    func copyImage(_ image:RasterImage) -> CopyOutcome { images.append(image); return outcome }
}

@MainActor private extension EditingCanvasView {
    func mouseDownOrUpForNumberTest(_ type:NSEvent.EventType,point:CGPoint,window:NSWindow) {
        let event = NSEvent.mouseEvent(with:type,location:convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,
            context:nil,eventNumber:0,clickCount:1,pressure:1)!
        if type == .leftMouseDown { mouseDown(with:event) } else { mouseUp(with:event) }
    }
}
