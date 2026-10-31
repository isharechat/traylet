import AppKit
import ImageIO
import Testing
import TrayletCore
@testable import TrayletApp

@Suite("Redaction") @MainActor struct RedactionTests {
    @Test func redactionIsOpaqueBlackRegardlessOfStyleAndBackground() throws {
        let tool = try #require(EditingTool(rawValue: "redaction"))
        for background in [NSColor.white, .red, .clear, NSColor(deviceRed:0.2,green:0.8,blue:1,alpha:0.3)] {
            let source = try fixture(width:20,height:16,color:background)
            var document = EditingDocument(canvas:CGSize(width:20,height:16),fullScreen:true)
            document.append(EditingMark(tool:tool,points:[CGPoint(x:3,y:4),CGPoint(x:12,y:10)],
                style:EditingStyle(color:.clear,width:20,filled:false)))
            let output = try EditingRenderer.render(source,document:document)
            try expectBlack(output,in:CGRect(x:3,y:4,width:9,height:6))
        }
    }

    private func fixture(width:Int,height:Int,color:NSColor) throws -> RasterImage {
        let context = try #require(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x:0,y:0,width:width,height:height))
        return try EditingRenderer.encode(#require(context.makeImage()))
    }

    @Test func fractionalCropAndNonuniformScaleCoverEveryTouchedPixelAfterAllOtherTools() throws {
        let source = try fixture(width:100,height:90,color:.white)
        var document = EditingDocument(canvas:CGSize(width:40,height:60))
        document.selectLive(from:CGPoint(x:1.1,y:2.2),to:CGPoint(x:30.2,y:50.4))
        document.append(EditingMark(tool:.redaction,points:[CGPoint(x:2.1,y:3.2),CGPoint(x:4.9,y:5.1)]))
        for tool in [EditingTool.rectangle,.ellipse,.line,.arrow,.pencil,.text,.highlight,.blur] {
            document.append(EditingMark(tool:tool,points:[CGPoint(x:0,y:0),CGPoint(x:15,y:15)],
                style:EditingStyle(color:.red,width:20,filled:true,fontSize:24,brushSize:60),text:"SECRET"))
        }
        let output = try EditingRenderer.render(source,document:document)
        #expect(output.width == 74 && output.height == 73)
        // Original image edges are x=8...15, y=8.1...10.95; crop starts at (2,3).
        try expectBlack(output,in:CGRect(x:6,y:5,width:7,height:3))
        let preview = EditingMark(tool:.rectangle,points:[.zero,CGPoint(x:25,y:25)],style:EditingStyle(color:.green,filled:true))
        try expectBlack(EditingRenderer.render(source,document:document,preview:preview),in:CGRect(x:6,y:5,width:7,height:3))
    }

    private func expectBlack(_ image:RasterImage,in rect:CGRect) throws {
        let bitmap = try #require(NSBitmapImageRep(data:image.pngData))
        for y in Int(rect.minY)..<Int(rect.maxY) { for x in Int(rect.minX)..<Int(rect.maxX) {
            let color = try #require(bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB))
            #expect(color.redComponent == 0 && color.greenComponent == 0 && color.blueComponent == 0 && color.alphaComponent == 1,
                "Pixel (\(x), \(y)) must be opaque black; got \(color)")
        } }
    }

    @Test func tinyDragIsKeptButZeroAreaAndCancelledDragsNeverEnterHistory() throws {
        _ = NSApplication.shared
        let session = EditingSession(image:try fixture(width:200,height:160,color:.white),canvas:CGSize(width:200,height:160),fullScreen:true,writer:RedactionOutput())
        session.tool = .redaction
        let canvas = EditingCanvasView(session:session,selectingForTranslation:false)
        let window = NSWindow(contentRect:canvas.bounds,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.contentView = nil; window.close() }
        func event(_ type:NSEvent.EventType,_ point:CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:0,
                windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        let start = CGPoint(x:40.2,y:40.2), end = CGPoint(x:40.3,y:40.4)
        canvas.mouseDown(with:event(.leftMouseDown,start))
        canvas.mouseDragged(with:event(.leftMouseDragged,end))
        canvas.mouseUp(with:event(.leftMouseUp,end))
        #expect(session.document.marks.count == 1)
        try expectBlack(session.composite(),in:CGRect(x:40,y:40,width:1,height:1))
        session.document.undo(); #expect(session.document.marks.isEmpty)
        session.document.redo(); #expect(session.document.marks.count == 1)
        session.document.append(EditingMark(tool:.redaction,points:[start,start]))
        session.document.append(EditingMark(tool:.redaction,points:[start,CGPoint(x:start.x,y:70)]))
        #expect(session.document.marks.count == 1)
        canvas.mouseDown(with:event(.leftMouseDown,CGPoint(x:60,y:60)))
        canvas.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:90,y:90)))
        var cancelled = 0; canvas.onCancel = { cancelled += 1 }
        canvas.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,
            windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:53)!)
        canvas.mouseUp(with:event(.leftMouseUp,CGPoint(x:90,y:90)))
        #expect(cancelled == 1 && session.document.marks.count == 1)
        #expect(!window.isVisible)
    }

    @Test func narrowToolbarFitsAndRedactionDoesNotOfferIneffectiveStyleControls() throws {
        _ = NSApplication.shared
        // Offscreen snapshots cannot render live glass; inspect the supported solid fallback explicitly.
        let previousGlass = V2AppearanceState.shared.glassEnabled
        V2AppearanceState.shared.glassEnabled = false
        defer { V2AppearanceState.shared.glassEnabled = previousGlass }
        for width in [180,320,900] {
            let writer = RedactionOutput()
            let session = EditingSession(image:try fixture(width:width,height:240,color:.white),
                canvas:CGSize(width:width,height:240),fullScreen:true,writer:writer)
            session.tool = .redaction
            let canvas = EditingCanvasView(session:session,selectingForTranslation:false)
            let window = NSWindow(contentRect:canvas.bounds,styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; window.contentView = canvas
            defer { window.contentView = nil; window.close() }
            canvas.layoutSubtreeIfNeeded()
            let toolbar = try #require(canvas.subviews.first)
            #expect(toolbar.intrinsicContentSize.width <= toolbar.frame.width + 1, "Every visible control must fit at \(width)pt")
            #expect(canvas.bounds.contains(toolbar.frame))
            #expect(canvas.subviews.last?.isHidden == true, "Redaction has no color, alpha, or stroke controls")
            var saved = 0; canvas.onSave = { saved += 1 }
            for (character,code) in [("c",UInt16(8)),("s",UInt16(1))] {
                canvas.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,
                    windowNumber:window.windowNumber,context:nil,characters:character,charactersIgnoringModifiers:character,isARepeat:false,keyCode:code)!)
            }
            #expect(writer.image != nil && saved == 1)
            #expect(!window.isVisible)
            for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",NSAppearance.Name.darkAqua)] {
                window.appearance = NSAppearance(named:appearance)
                let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds))
                canvas.cacheDisplay(in:canvas.bounds,to:bitmap)
                try #require(bitmap.representation(using:.png,properties:[:])).write(to:evidenceURL("toolbar-\(width)-\(name).png"))
            }
        }
    }

    @Test func copySaveAndLiveCompositionContainOnlyFinalOpaquePixels() throws {
        let source = try fixture(width:100,height:80,color:NSColor(deviceRed:1,green:0.5,blue:0.2,alpha:0.4))
        let writer = RedactionOutput()
        let session = EditingSession(image:source,canvas:CGSize(width:50,height:40),fullScreen:true,writer:writer)
        session.document.append(EditingMark(tool:.redaction,points:[CGPoint(x:60,y:50),CGPoint(x:-10,y:-10)]))
        let output = try session.composite()
        try expectBlack(output,in:CGRect(x:0,y:0,width:100,height:80))
        let live = try EditingRenderer.encode(#require(session.compositeImage()))
        #expect(live.pngData == output.pngData)
        #expect(session.copy())
        #expect(writer.image?.pngData == output.pngData)
        let url = try evidenceURL("final-opaque.png")
        #expect(session.save(to:url))
        #expect(try Data(contentsOf:url) == output.pngData)
        let encoded = try #require(CGImageSourceCreateWithData(output.pngData as CFData,nil))
        #expect(CGImageSourceGetCount(encoded) == 1)
        // A plain PNG contains one flattened raster, no text or additional source/layer payload.
        var offset = 8
        var chunkTypes: [String] = []
        while offset + 12 <= output.pngData.count {
            let bytes = Array(output.pngData[offset..<(offset+4)])
            let length = bytes.reduce(0) { ($0 << 8) | Int($1) }
            let kind = String(decoding:output.pngData[(offset+4)..<(offset+8)],as:UTF8.self)
            chunkTypes.append(kind); offset += length + 12
        }
        #expect(offset == output.pngData.count)
        #expect(Set(chunkTypes).isSubset(of:["IHDR","IDAT","IEND","sRGB","gAMA","cHRM","iCCP","pHYs","eXIf"]))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(encoded,0,nil) as? [String:Any])
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String:Any] {
            // ImageIO may synthesize dimension-only EXIF even when encoding a new bitmap without metadata.
            #expect(Set(exif.keys).isSubset(of:[kCGImagePropertyExifPixelXDimension as String,kCGImagePropertyExifPixelYDimension as String]))
        }
        session.document.undo()
        let uncovered = try session.composite()
        #expect(uncovered.pngData != output.pngData)
        session.document.redo()
        #expect(try session.composite().pngData == output.pngData)
    }

    @Test func subpixelCoverageIsConservativeWithoutChangingUntouchedPixels() throws {
        let source = try fixture(width:100,height:90,color:.white)
        let original = try #require(NSBitmapImageRep(data:source.pngData)?.colorAt(x:0,y:0)?.usingColorSpace(.deviceRGB))
        #expect(original.redComponent > 0.99 && original.greenComponent > 0.99 && original.blueComponent > 0.99)
        var document = EditingDocument(canvas:CGSize(width:40,height:60))
        document.selectLive(from:CGPoint(x:1.1,y:2.2),to:CGPoint(x:30.2,y:50.4))
        document.append(EditingMark(tool:.redaction,points:[CGPoint(x:4.9,y:5.1),CGPoint(x:2.1,y:3.2)]))
        let output = try EditingRenderer.render(source,document:document)
        try expectBlack(output,in:CGRect(x:6,y:5,width:7,height:3))
        let bitmap = try #require(NSBitmapImageRep(data:output.pngData))
        for point in [CGPoint(x:5,y:5),CGPoint(x:13,y:5),CGPoint(x:6,y:4),CGPoint(x:6,y:8)] {
            let color = try #require(bitmap.colorAt(x:Int(point.x),y:Int(point.y))?.usingColorSpace(.deviceRGB))
            #expect(color.redComponent == original.redComponent && color.greenComponent == original.greenComponent && color.blueComponent == original.blueComponent)
        }
        // Touching the last fraction of the selection also covers the outward-rounded crop boundary.
        document.append(EditingMark(tool:.redaction,points:[CGPoint(x:29,y:48),CGPoint(x:35,y:55)]))
        try expectBlack(EditingRenderer.render(source,document:document),in:CGRect(x:73,y:72,width:1,height:1))
    }

    @Test func hiddenCanvasShowsBlackDuringDragAndAboveLaterPreview() throws {
        _ = NSApplication.shared
        let session = EditingSession(image:try fixture(width:400,height:300,color:.white),
            canvas:CGSize(width:400,height:300),fullScreen:true,writer:RedactionOutput())
        session.tool = .redaction
        let canvas = EditingCanvasView(session:session,selectingForTranslation:false)
        let window = NSWindow(contentRect:canvas.bounds,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.contentView = nil; window.close() }
        func event(_ type:NSEvent.EventType,_ point:CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:0,
                windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        func snapshot(_ name:String) throws {
            canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded()
            let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds))
            canvas.cacheDisplay(in:canvas.bounds,to:bitmap)
            let color = try #require(bitmap.colorAt(x:bitmap.pixelsWide/4,y:bitmap.pixelsHigh/3)?.usingColorSpace(.deviceRGB))
            #expect(color.redComponent == 0 && color.greenComponent == 0 && color.blueComponent == 0 && color.alphaComponent == 1)
            try #require(bitmap.representation(using:.png,properties:[:])).write(to:evidenceURL(name))
        }
        canvas.mouseDown(with:event(.leftMouseDown,CGPoint(x:70,y:70)))
        canvas.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:150,y:140)))
        #expect(session.document.marks.isEmpty)
        try snapshot("drag-preview.png")
        canvas.mouseUp(with:event(.leftMouseUp,CGPoint(x:150,y:140)))
        session.tool = .rectangle; session.style = EditingStyle(color:.red,filled:true)
        canvas.mouseDown(with:event(.leftMouseDown,CGPoint(x:50,y:50)))
        canvas.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:180,y:180)))
        try snapshot("later-annotation-preview.png")
        #expect(!window.isVisible)
    }

    private func evidenceURL(_ name:String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-redaction-evidence",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        return directory.appendingPathComponent(name)
    }
}

@MainActor private final class RedactionOutput: ImageOutputWriting {
    var image: RasterImage?
    func copyImage(_ image:RasterImage) -> CopyOutcome { self.image = image; return .copied }
}
