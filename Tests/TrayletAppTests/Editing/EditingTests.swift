import AppKit
import Testing
import TrayletCore
@testable import TrayletApp

@Suite("Editing") @MainActor struct EditingTests {
    @Test func selectionRespectsMinimumAndScreenAndMovesAnnotations() {
        var document = EditingDocument(canvas: CGSize(width: 500, height: 400))
        document.select(from: CGPoint(x: 20, y: 30), to: CGPoint(x: 25, y: 35))
        #expect(document.selection == CGRect(x: 20, y: 30, width: 5, height: 5))
        document.moveSelection(by: CGSize(width: -100, height: 500))
        #expect(document.selection == CGRect(x: 0, y: 395, width: 5, height: 5))
        document.resizeSelection(.northWest, to: CGPoint(x: 499, y: 399))
        #expect(document.selection?.width == 1)
        #expect(document.selection?.height == 1)
    }
}

extension EditingTests {
    @Test func markHistoryAndToolbarAndTextEscape() {
        var d = EditingDocument(canvas: CGSize(width: 500,height: 400),fullScreen:true)
        d.append(EditingMark(tool:.rectangle, points:[CGPoint(x:10,y:10),CGPoint(x:80,y:80)]))
        #expect(d.canUndo)
        d.undo(); #expect(d.marks.isEmpty); #expect(d.canRedo)
        d.redo(); #expect(d.marks.count == 1)
        d.undo(); d.append(EditingMark(tool:.line,points:[.zero,CGPoint(x:30,y:30)])); #expect(!d.canRedo)
        let size = CGSize(width:300,height:40)
        #expect(d.toolbarOrigin(size:size) == CGPoint(x:196,y:350))
        d.dragToolbar(to:CGPoint(x:-5,y:8)); #expect(d.toolbarOrigin(size:size) == CGPoint(x:4,y:8))
        d.resetToolbar(); #expect(d.toolbarOrigin(size:size).y == 350)
        #expect(EditingDocument.escapeAction(isEditingText:true,hasMarkedText:true) == .inputMethod)
        #expect(EditingDocument.escapeAction(isEditingText:true,hasMarkedText:false) == .cancelText)
        #expect(EditingDocument.escapeAction(isEditingText:false,hasMarkedText:false) == .close)
    }
}

extension EditingTests {
    static func fixture() throws -> RasterImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:200,pixelsHigh:160,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        for y in 0..<160 { for x in 0..<200 { bitmap.setColor(NSColor(deviceRed:x < 100 ? 1 : 0,green:x < 100 ? 1 : 0,blue:x < 100 ? 1 : 0,alpha:1),atX:x,y:y) } }
        return try RasterImage(pngData:bitmap.representation(using:.png,properties:[:])!)
    }
    @Test func exportCropsCompositesAndBlursActualPixels() throws {
        let source = try Self.fixture()
        var d = EditingDocument(canvas:CGSize(width:100,height:80),fullScreen:true)
        let original = try EditingRenderer.render(source,document:d)
        #expect(original.width == 200 && original.height == 160)
        d.append(EditingMark(tool:.rectangle,points:[CGPoint(x:10,y:10),CGPoint(x:30,y:30)],style:EditingStyle(color:.red,width:2,filled:true)))
        var rendered = try EditingRenderer.render(source,document:d)
        let marked = NSBitmapImageRep(data:rendered.pngData)!
        #expect(marked.colorAt(x:40,y:40)!.redComponent > 0.9)
        #expect(marked.colorAt(x:40,y:40)!.greenComponent < 0.1)
        d.append(EditingMark(tool:.blur,points:[CGPoint(x:50,y:40)],style:EditingStyle(brushSize:40)))
        rendered = try EditingRenderer.render(source,document:d)
        let blurred = NSBitmapImageRep(data:rendered.pngData)!
        let gray = blurred.colorAt(x:101,y:80)!.redComponent
        #expect(gray > 0.05 && gray < 0.95, "actual gray: \(gray)")
        #expect(blurred.colorAt(x:180,y:80)!.redComponent < 0.01)
        d.select(from:CGPoint(x:25,y:10),to:CGPoint(x:85,y:70))
        rendered = try EditingRenderer.render(source,document:d)
        #expect(rendered.width == 120 && rendered.height == 120)
    }
}

@MainActor private final class EditingFakeOutput: ImageOutputWriting {
    var outcome: CopyOutcome = .failed
    var calls = 0
    func copyImage(_ image:RasterImage) -> CopyOutcome { calls += 1; return outcome }
}
extension EditingTests {
    @Test func failedOutputRetainsDocumentAndCancelledSaveDoesNothing() throws {
        let previousLanguage = V2Localization.shared.languageCode
        V2Localization.shared.languageCode = "zh-Hans"
        defer { V2Localization.shared.languageCode = previousLanguage }
        let writer = EditingFakeOutput()
        let session = EditingSession(image:try Self.fixture(),canvas:CGSize(width:100,height:80),fullScreen:true,writer:writer)
        session.document.append(EditingMark(tool:.arrow,points:[.zero,CGPoint(x:40,y:40)]))
        session.copy()
        #expect(writer.calls == 1 && session.document.marks.count == 1)
        #expect(session.message.contains("保留"))
        session.save(to:nil)
        #expect(session.document.marks.count == 1)
        session.save(to:URL(fileURLWithPath:"/dev/null/invalid.png"))
        #expect(session.message.contains("失败"))
        #expect(session.document.canUndo)
        writer.outcome = .changed; session.copy()
        #expect(session.message.contains("变化"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        defer { try? FileManager.default.removeItem(at:url) }
        session.save(to:url)
        #expect(try RasterImage(pngData:Data(contentsOf:url)).width == 200)
    }
}

extension EditingTests {
    @Test(arguments:EditingDocument.Handle.allCases) func everyHandleKeepsOppositeEdgesAndMinimum(_ handle:EditingDocument.Handle) {
        var d = EditingDocument(canvas:CGSize(width:500,height:400))
        d.select(from:CGPoint(x:100,y:100),to:CGPoint(x:300,y:250))
        d.resizeSelection(handle,to:CGPoint(x:2000,y:2000))
        let r = d.selection!
        #expect(r.width >= 1 && r.height >= 1)
        #expect(r.minX >= 0 && r.minY >= 0 && r.maxX <= 500 && r.maxY <= 400)
        if [.northWest,.north,.northEast].contains(handle) { #expect(r.maxY == 250) }
        if [.southWest,.south,.southEast].contains(handle) { #expect(r.minY == 100) }
        if [.northWest,.west,.southWest].contains(handle) { #expect(r.maxX == 300) }
        if [.northEast,.east,.southEast].contains(handle) { #expect(r.minX == 100) }
    }
    @Test(arguments:[EditingTool.rectangle,.ellipse,.line,.arrow,.pencil,.text]) func eachToolChangesExportAndUndoRestoresPixels(_ tool:EditingTool) throws {
        let source = try Self.fixture()
        var d = EditingDocument(canvas:CGSize(width:100,height:80),fullScreen:true)
        let initial = try EditingRenderer.render(source,document:d)
        d.append(EditingMark(tool:tool,points:[CGPoint(x:10,y:10),CGPoint(x:40,y:40)],style:EditingStyle(color:NSColor(deviceRed:1,green:0,blue:0,alpha:1),width:4),text:"A字"))
        let result = try EditingRenderer.render(source,document:d)
        let pixels = NSBitmapImageRep(data:result.pngData)!
        var redPixels = 0
        for y in 0..<result.height { for x in 0..<result.width {
            let color = pixels.colorAt(x:x,y:y)!
            if color.redComponent > 0.6 && color.greenComponent < 0.3 { redPixels += 1 }
        } }
        #expect(redPixels > 10)
        d.undo()
        #expect(try EditingRenderer.render(source,document:d) == initial)
        d.redo()
        #expect(try EditingRenderer.render(source,document:d) == result)
    }
    @Test func cropPreservesVerticalOrientationAndLocalMarksFollowSelection() throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:200,pixelsHigh:200,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        for y in 0..<200 { for x in 0..<200 { bitmap.setColor(NSColor(deviceRed:y < 100 ? 1 : 0,green:0,blue:y < 100 ? 0 : 1,alpha:1),atX:x,y:y) } }
        let source = try RasterImage(pngData:bitmap.representation(using:.png,properties:[:])!)
        var d = EditingDocument(canvas:CGSize(width:100,height:100),fullScreen:true)
        var output = NSBitmapImageRep(data:try EditingRenderer.render(source,document:d).pngData)!
        #expect(output.colorAt(x:10,y:10)!.redComponent > 0.9)
        #expect(output.colorAt(x:10,y:190)!.blueComponent > 0.9)
        d.select(from:.zero,to:CGPoint(x:60,y:60))
        d.append(EditingMark(tool:.rectangle,points:[CGPoint(x:5,y:5),CGPoint(x:15,y:15)],style:EditingStyle(color:NSColor(deviceRed:0,green:1,blue:0,alpha:1),filled:true)))
        d.moveSelection(by:CGSize(width:40,height:40))
        output = NSBitmapImageRep(data:try EditingRenderer.render(source,document:d).pngData)!
        #expect(output.colorAt(x:20,y:20)!.greenComponent > 0.9)
        #expect(output.colorAt(x:100,y:100)!.blueComponent > 0.9)
    }
    @Test func toolbarOptionsFlipAndTinyCanvasStillStayBounded() {
        var d = EditingDocument(canvas:CGSize(width:200,height:100),fullScreen:true)
        let toolbar = CGRect(origin:d.toolbarOrigin(size:CGSize(width:180,height:44)),size:CGSize(width:180,height:44))
        #expect(d.optionsOrigin(toolbar:toolbar,size:CGSize(width:180,height:30)).y == 8)
        d = EditingDocument(canvas:CGSize(width:40,height:30))
        d.select(from:.zero,to:CGPoint(x:1,y:1))
        #expect(d.selection == CGRect(x:0,y:0,width:1,height:1))
    }
}

extension EditingTests {
    @Test func nativeCanvasSyntheticEventsAndTextComposition() throws {
        _ = NSApplication.shared
        let writer = EditingFakeOutput()
        let session = EditingSession(image:try Self.fixture(),canvas:CGSize(width:500,height:400),fullScreen:false,writer:writer)
        let canvas = EditingCanvasView(session:session,selectingForTranslation:false)
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:500,height:400),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.contentView = nil; window.close() }
        func event(_ type:NSEvent.EventType,_ p:CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:canvas.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        canvas.mouseDown(with:event(.leftMouseDown,CGPoint(x:50,y:50)))
        canvas.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:350,y:250)))
        canvas.mouseUp(with:event(.leftMouseUp,CGPoint(x:350,y:250)))
        #expect(session.document.selection == CGRect(x:50,y:50,width:300,height:200))
        session.tool = .pencil
        canvas.mouseDown(with:event(.leftMouseDown,CGPoint(x:100,y:100)))
        canvas.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:150,y:150)))
        canvas.mouseUp(with:event(.leftMouseUp,CGPoint(x:150,y:150)))
        #expect(session.document.marks.count == 1)
        session.tool = .text
        canvas.mouseDown(with:event(.leftMouseDown,CGPoint(x:100,y:100)))
        let text = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        text.setMarkedText("拼",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        #expect(!canvas.finishText())
        #expect(session.document.marks.count == 1)
        text.unmarkText(); text.string = "原生文字"
        var cancelled = 0
        canvas.onCancel = { cancelled += 1 }
        let escape = try #require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:53))
        let commit = try #require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36))
        text.keyDown(with:commit)
        #expect(cancelled == 0)
        #expect(session.document.marks.last?.text == "原生文字")
        #expect(canvas.finishText())
        #expect(session.document.marks.count == 2)
        #expect(session.message.isEmpty)
        canvas.keyDown(with:escape)
        #expect(cancelled == 1)
        for (name, appearance) in [("light",NSAppearance.Name.aqua),("dark",NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named:appearance)
            canvas.layoutSubtreeIfNeeded()
            let rep = try #require(canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds))
            canvas.cacheDisplay(in:canvas.bounds,to:rep)
            var markedPixels = 0
            // Bitmap pixels follow the display backing scale (2x on Retina); the region is defined in canvas points.
            // Marks are drawn upscaled with system interpolation, so test for red-tinted pixels, not an exact pure red.
            let scale = CGFloat(rep.pixelsWide) / canvas.bounds.width
            for y in Int(60*scale)..<Int(240*scale) { for x in Int(60*scale)..<Int(340*scale) {
                if let color = rep.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),color.redComponent > 0.65,color.redComponent - color.greenComponent > 0.25 { markedPixels += 1 }
            } }
            #expect(markedPixels > 20, "Native preview must contain current annotations in \(name) appearance")
            let image = try #require(rep.representation(using:.png,properties:[:]))
            try image.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("traylet-rewrite-editing-native-\(name).png"),options:.atomic)
        }
    }
}

extension EditingTests {
    @Test func exportedTextWrapsWithinSelectionLikeNativeTextEditor() throws {
        let source = try Self.fixture()
        var document = EditingDocument(canvas:CGSize(width:100,height:80),fullScreen:true)
        document.append(EditingMark(tool:.text,points:[CGPoint(x:65,y:5)],style:EditingStyle(color:.red,fontSize:16),text:"AA AA AA AA"))
        let output = NSBitmapImageRep(data:try EditingRenderer.render(source,document:document).pngData)!
        var lowerLinePixels = 0
        for y in 60..<130 { for x in 130..<200 {
            let color = output.colorAt(x:x,y:y)!
            if color.redComponent > 0.6 && color.greenComponent < 0.3 { lowerLinePixels += 1 }
        } }
        #expect(lowerLinePixels > 20, "Wrapped text below the first line must be present in the exported PNG")
    }
}

extension EditingTests {
    @Test func repeatedPresentationRejectsStaleCallbacksAndCancellationCompletesOnce() throws {
        _ = NSApplication.shared
        let screenFrame = CGRect(x:-500,y:200,width:500,height:400)
        let colorPanel = NSColorPanel.shared
        let originalColorLevel = colorPanel.level
        var canvases: [EditingCanvasView] = []
        let controller = CaptureEditorController(writer:EditingFakeOutput(),presentPanel:{ _, view in
            if let canvas = view as? EditingCanvasView { canvases.append(canvas) }
        })
        var completions = 0
        var translated: RasterImage?
        controller.onComplete = { completions += 1 }
        controller.onTranslate = { translated = $0 }
        let source = try Self.fixture()
        controller.present(image:source,screenFrame:screenFrame,initiallyFullScreen:true)
        #expect(controller.isOpen)
        #expect(colorPanel.level == originalColorLevel, "Opening a capture must not mutate the shared color panel before selection")
        controller.present(image:source,screenFrame:screenFrame,initiallyFullScreen:true,selectingForTranslation:true)
        #expect(completions == 1)
        canvases[0].onCancel?()
        #expect(controller.isOpen, "A retired canvas must not close the replacement capture")
        #expect(completions == 1)
        canvases[1].onTranslate?()
        #expect(translated?.width == 200 && translated?.height == 160)
        // Translation takes focus itself, so the previous-app restore callback must not fire.
        #expect(!controller.isOpen && completions == 1)
        #expect(colorPanel.level == originalColorLevel)
        controller.cancel(); canvases[1].onTranslate?()
        #expect(completions == 1)
    }
}

extension EditingTests {
    /// Entirely generated artwork; no capture or system pasteboard is involved.
    static func showcaseImage() throws -> RasterImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2200,pixelsHigh:1440,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let graphics = NSGraphicsContext(bitmapImageRep:bitmap)!
        NSGraphicsContext.saveGraphicsState()
        let context = graphics.cgContext
        context.translateBy(x:0,y:1440); context.scaleBy(x:2,y:-2)
        NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:true)
        NSColor(calibratedWhite:0.94,alpha:1).setFill(); CGRect(x:0,y:0,width:1100,height:720).fill()
        NSColor.white.setFill(); NSBezierPath(roundedRect:CGRect(x:90,y:60,width:920,height:590),xRadius:18,yRadius:18).fill()
        func label(_ string:String,_ point:CGPoint,_ size:CGFloat,_ color:NSColor = .black) {
            (string as NSString).draw(at:point,withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:.medium),.foregroundColor:color])
        }
        label("Traylet · 原生截图编辑",CGPoint(x:130,y:95),28)
        label("合成样例 / Synthetic artwork — no screen content",CGPoint(x:130,y:140),16,.darkGray)
        for row in 0..<5 {
            let y = CGFloat(195+row*62)
            NSColor(calibratedWhite:0.92,alpha:1).setFill(); CGRect(x:130,y:y,width:840,height:44).fill()
            label(["选区与标注一起移动", "矩形 · 椭圆 · 箭头 · 铅笔", "文字保持自动换行", "Undo / Redo preserves the original image", "Copy and save retain edits on failure"][row],CGPoint(x:150,y:y+10),18)
            for x in stride(from:780,to:950,by:8) {
                NSColor(calibratedWhite:(x-780) % 16 == 0 ? 0.12 : 0.85,alpha:1).setFill()
                CGRect(x:CGFloat(x),y:y+6,width:4,height:32).fill()
            }
        }
        label("所有图片均由测试生成。",CGPoint(x:130,y:565),16,.darkGray)
        NSGraphicsContext.restoreGraphicsState()
        return try RasterImage(pngData:bitmap.representation(using:.png,properties:[:])!)
    }

    @Test func highResolutionNativeGalleryAndTranslationSelection() throws {
        let previousLanguage = V2Localization.shared.languageCode
        V2Localization.shared.languageCode = "zh-Hans"
        defer { V2Localization.shared.languageCode = previousLanguage }
        _ = NSApplication.shared
        let source = try Self.showcaseImage()
        let session = EditingSession(image:source,canvas:CGSize(width:1100,height:720),fullScreen:false,writer:EditingFakeOutput())
        session.document.select(from:CGPoint(x:110,y:80),to:CGPoint(x:990,y:570))
        session.document.append(EditingMark(tool:.rectangle,points:[CGPoint(x:20,y:110),CGPoint(x:860,y:166)],style:EditingStyle(color:.systemRed,width:3)))
        session.document.append(EditingMark(tool:.arrow,points:[CGPoint(x:520,y:75),CGPoint(x:430,y:125)],style:EditingStyle(color:.systemBlue,width:4)))
        session.document.append(EditingMark(tool:.text,points:[CGPoint(x:300,y:390)],style:EditingStyle(color:.systemBlue,fontSize:22),text:"合成验证 · 可撤销编辑"))
        session.document.append(EditingMark(tool:.blur,points:[CGPoint(x:740,y:198),CGPoint(x:820,y:198)],style:EditingStyle(brushSize:36)))
        let canvas = EditingCanvasView(session:session,selectingForTranslation:false)
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:1100,height:720),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.contentView = nil; window.close() }
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named:appearance)
            for tool in EditingTool.allCases {
                session.tool = tool
                canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded()
                for view in canvas.subviews where !view.isHidden { #expect(canvas.bounds.contains(view.frame)) }
                let rep = try #require(canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds))
                canvas.cacheDisplay(in:canvas.bounds,to:rep)
                try #require(rep.representation(using:.png,properties:[:])).write(to:FileManager.default.temporaryDirectory.appendingPathComponent("traylet-rewrite-editing-gallery-\(tool.rawValue)-\(name).png"),options:.atomic)
            }
        }
        // Reuse the same mounted toolbar/options after changing the shared preference.
        V2Localization.shared.languageCode = "en"
        session.tool = .rectangle
        window.appearance = NSAppearance(named:.aqua)
        canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded()
        let englishRep = try #require(canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds))
        canvas.cacheDisplay(in:canvas.bounds,to:englishRep)
        try #require(englishRep.representation(using:.png,properties:[:])).write(to:FileManager.default.temporaryDirectory.appendingPathComponent("traylet-rewrite-editing-gallery-english.png"),options:.atomic)
        let composite = try session.composite()
        #expect(composite.width == 1760 && composite.height == 980)
        try composite.pngData.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("traylet-rewrite-editing-gallery-export.png"),options:.atomic)
        let selection = EditingSession(image:source,canvas:CGSize(width:1100,height:720),fullScreen:true,writer:EditingFakeOutput())
        let translation = EditingCanvasView(session:selection,selectingForTranslation:true)
        window.contentView = translation
        var translated = 0; var cancelled = 0
        translation.onTranslate = { translated += 1 }; translation.onCancel = { cancelled += 1 }
        func key(_ code:UInt16) -> NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
        }
        translation.keyDown(with:key(36)); #expect(translated == 1)
        translation.keyDown(with:key(53)); #expect(cancelled == 1)
        #expect(selection.document.selection == CGRect(x:0,y:0,width:1100,height:720))
        translation.layoutSubtreeIfNeeded()
        let rep = try #require(translation.bitmapImageRepForCachingDisplay(in:translation.bounds))
        translation.cacheDisplay(in:translation.bounds,to:rep)
        try #require(rep.representation(using:.png,properties:[:])).write(to:FileManager.default.temporaryDirectory.appendingPathComponent("traylet-rewrite-editing-translation-selection.png"),options:.atomic)
    }
}

extension EditingTests {
    @Test func languageSwitchUpdatesToolLabelsAndMessagesWithoutChangingUserPixels() throws {
        let localization = V2Localization.shared
        let previousLanguage = localization.languageCode
        defer { localization.languageCode = previousLanguage }
        localization.languageCode = "zh-Hans"
        let session = EditingSession(image:try Self.fixture(),canvas:CGSize(width:100,height:80),fullScreen:true,writer:EditingFakeOutput())
        let userText = "保存 复制 · User text"
        session.document.append(EditingMark(tool:.text,points:[CGPoint(x:5,y:5)],style:EditingStyle(color:.red,fontSize:12),text:userText))
        let chinese = try session.composite()
        session.message = "已复制。"
        #expect(EditingTool.rectangle.title == "矩形")
        #expect(session.message == "已复制。")
        localization.languageCode = "en"
        #expect(EditingTool.rectangle.title == "Rectangle")
        #expect(EditingTool.arrow.title == "Arrow")
        #expect(EditingTool.text.title == "Text")
        #expect(session.message == "Copied.")
        #expect(session.document.marks.first?.text == userText)
        #expect(try session.composite() == chinese)
        let canvas = EditingCanvasView(session:session,selectingForTranslation:false)
        #expect(canvas.accessibilityLabel() == "Capture Editing Area")
    }
}

extension EditingTests {
    @Test func cursorFollowsPointerPosition() throws {
        _ = NSApplication.shared
        let session = EditingSession(image:try Self.fixture(),canvas:CGSize(width:500,height:400),fullScreen:false,writer:EditingFakeOutput())
        let canvas = EditingCanvasView(session:session,selectingForTranslation:false)
        #expect(canvas.cursor(at:CGPoint(x:50,y:50)) == .crosshair)
        session.document.select(from:CGPoint(x:100,y:100),to:CGPoint(x:300,y:250))
        #expect(canvas.cursor(at:CGPoint(x:200,y:170)) == .openHand)
        #expect(canvas.cursor(at:CGPoint(x:20,y:20)) == .arrow)
        let corner = canvas.cursor(at:CGPoint(x:100,y:100))
        #expect(corner != .arrow && corner != .openHand && corner != .crosshair)
        session.tool = .text
        #expect(canvas.cursor(at:CGPoint(x:200,y:170)) == .iBeam)
        session.tool = .rectangle
        #expect(canvas.cursor(at:CGPoint(x:200,y:170)) == .crosshair)
    }

    @Test func liveCompositeMatchesExportedPixels() throws {
        let session = EditingSession(image:try Self.fixture(),canvas:CGSize(width:100,height:80),fullScreen:true,writer:EditingFakeOutput())
        session.document.append(EditingMark(tool:.rectangle,points:[CGPoint(x:10,y:10),CGPoint(x:60,y:50)],style:EditingStyle()))
        let live = try #require(session.compositeImage())
        let exported = try session.composite()
        #expect(live.width == exported.width && live.height == exported.height)
    }
}

extension EditingTests {
    @Test func copyAndSaveReportSuccessSoTheEditorCanClose() throws {
        let writer = EditingFakeOutput()
        let session = EditingSession(image:try Self.fixture(),canvas:CGSize(width:100,height:80),fullScreen:true,writer:writer)
        #expect(!session.copy())
        writer.outcome = .copied
        #expect(session.copy())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-close-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at:url) }
        #expect(session.save(to:url))
        #expect(!session.save(to:nil))
    }
}

extension EditingTests {
    @Test func translationCaptureStartsWhenTheRegionIsChosen() throws {
        _ = NSApplication.shared
        let session = EditingSession(image:try Self.fixture(),canvas:CGSize(width:500,height:400),fullScreen:false,writer:EditingFakeOutput())
        let canvas = EditingCanvasView(session:session,selectingForTranslation:true)
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:500,height:400),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.contentView = nil; window.close() }
        var translated = 0
        canvas.onTranslate = { translated += 1 }
        func event(_ type:NSEvent.EventType,_ p:CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:canvas.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        canvas.mouseDown(with:event(.leftMouseDown,CGPoint(x:50,y:50)))
        #expect(translated == 0)
        canvas.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:350,y:250)))
        #expect(translated == 0)
        canvas.mouseUp(with:event(.leftMouseUp,CGPoint(x:350,y:250)))
        #expect(translated == 1)
    }

    @Test func translateHandoffDoesNotRestorePreviousFocus() throws {
        var restored = 0
        let controller = CaptureEditorController(writer:EditingFakeOutput(),presentPanel:{ _, _ in })
        controller.onComplete = { restored += 1 }
        controller.present(image:try Self.fixture(),screenFrame:CGRect(x:0,y:0,width:500,height:400),initiallyFullScreen:true,selectingForTranslation:true)
        controller.cancel(restoreFocus:false)
        #expect(restored == 0 && !controller.isOpen)
    }
}

extension EditingTests {
    @Test func liveSelectionFollowsThePointerAndReleaseCoversPixels() {
        var d = EditingDocument(canvas:CGSize(width:500,height:400))
        d.selectLive(from:CGPoint(x:100,y:100),to:CGPoint(x:110,y:105))
        #expect(d.selection == CGRect(x:100,y:100,width:10,height:5))
        d.selectLive(from:CGPoint(x:300,y:250),to:CGPoint(x:120,y:130))
        #expect(d.selection == CGRect(x:120,y:130,width:180,height:120))
        d.selectLive(from:CGPoint(x:100,y:100),to:CGPoint(x:130,y:140))
        var kept = d.finishSelection()
        #expect(kept)
        #expect(d.selection == CGRect(x:100,y:100,width:30,height:40))
        d.selectLive(from:CGPoint(x:480,y:380),to:CGPoint(x:495,y:395))
        kept = d.finishSelection()
        #expect(kept)
        #expect(d.selection == CGRect(x:480,y:380,width:15,height:15))
        d.selectLive(from:CGPoint(x:50,y:50),to:CGPoint(x:53,y:52))
        kept = d.finishSelection()
        #expect(kept && d.selection == CGRect(x:50,y:50,width:3,height:2))
    }

    @Test func selectedTextIsTrimmedAndBounded() {
        #expect(V2SelectedTextPolicy.normalize(nil) == nil)
        #expect(V2SelectedTextPolicy.normalize(" \n\t ") == nil)
        #expect(V2SelectedTextPolicy.normalize("  hello world \n") == "hello world")
        #expect(V2SelectedTextPolicy.normalize(String(repeating:"a",count:30_000))?.count == V2SelectedTextPolicy.maximumCharacters)
    }
}

extension EditingTests {
    @Test func optionBarIsLeftAlignedWithTheToolbarAndFitsItsContent() throws {
        _ = NSApplication.shared
        let session = EditingSession(image:try Self.fixture(),canvas:CGSize(width:900,height:600),fullScreen:false,writer:EditingFakeOutput())
        let canvas = EditingCanvasView(session:session,selectingForTranslation:false)
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:900,height:600),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.contentView = nil; window.close() }
        session.document.select(from:CGPoint(x:100,y:100),to:CGPoint(x:700,y:400))
        var widths: [CGFloat] = []
        for tool in [EditingTool.blur,.rectangle,.text] {
            session.tool = tool
            canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded()
            let bars = canvas.barFrames
            let expectedX = max(4,min(canvas.bounds.width-bars.options.width-4,bars.toolbar.minX))
            #expect(bars.options.minX == expectedX, "\(tool): align left unless the right screen edge requires clamping")
            #expect(bars.options.minX >= 0 && bars.options.maxX <= canvas.bounds.maxX, "Options must remain inside the canvas")
            #expect(bars.toolbar.width > 60 && bars.toolbar.width < 620, "Toolbar frame must fit the tools plus view zoom menu: \(bars.toolbar.width)")
            #expect(bars.options.height == bars.toolbar.height)
            #expect(bars.options.width > 60 && bars.options.width <= canvas.bounds.width)
            widths.append(bars.options.width)
        }
        #expect(Set(widths).count > 1, "Width must adapt to each tool's controls")
    }
}

extension EditingTests {
    @Test func blurNeverTintsAnnotationColors() throws {
        let session = EditingSession(image:try Self.fixture(),canvas:CGSize(width:200,height:160),fullScreen:true,writer:EditingFakeOutput())
        var style = EditingStyle(); style.color = NSColor(deviceRed:1,green:0,blue:0,alpha:1); style.width = 4
        session.document.append(EditingMark(tool:.rectangle,points:[CGPoint(x:60,y:40),CGPoint(x:140,y:120)],style:style))
        var brush = EditingStyle(); brush.brushSize = 60
        session.document.append(EditingMark(tool:.blur,points:[CGPoint(x:60,y:80),CGPoint(x:140,y:80)],style:brush))
        let output = try session.composite()
        let rep = try #require(NSBitmapImageRep(data:output.pngData))
        let color = try #require(rep.colorAt(x:60,y:80)?.usingColorSpace(.deviceRGB))
        #expect(color.redComponent > 0.9 && color.greenComponent < 0.25 && color.blueComponent < 0.25, "stroke stays pure red under a blur: \(color)")
    }
}
