import AppKit
import Testing
import TrayletCore
@testable import TrayletApp

@MainActor struct ObjectEditingTests {
    @Test func existingNumberAndArrowMoveOnTheirOwnToolWithoutCreatingAnotherMark() throws {
        _ = NSApplication.shared
        for tool in [EditingTool.number,.arrow] {
            let s = EditingSession(image:try EditingTests.fixture(),canvas:CGSize(width:400,height:320),fullScreen:true,writer:ObjectWriter())
            let points = tool == .number ? [CGPoint(x:100,y:100)] : [CGPoint(x:80,y:100),CGPoint(x:160,y:100)]
            s.document.append(EditingMark(tool:tool,points:points)); s.tool = tool
            let view = EditingCanvasView(session:s,selectingForTranslation:false)
            let window = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; window.contentView = view
            defer { window.contentView = nil; window.close() }
            func mouse(_ type:NSEvent.EventType,_ point:CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,
                    context:nil,eventNumber:0,clickCount:1,pressure:1)!
            }
            view.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:100,y:100)))
            view.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:106,y:104)))
            view.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:108,y:106)))
            #expect(s.document.marks.count == 1)
            #expect(s.document.marks.first?.points == points.map { CGPoint(x:$0.x+8,y:$0.y+6) })
            s.document.undo(); #expect(s.document.marks.first?.points == points)
            s.document.redo(); #expect(s.document.marks.first?.points == points.map { CGPoint(x:$0.x+8,y:$0.y+6) })
            #expect(!window.isVisible)
        }
    }
    @Test func selectedObjectColorWellReadsAndEditsObjectWithoutChangingCreationDefaults() async throws {
        _ = NSApplication.shared
        for tool in [EditingTool.number,.arrow] {
            let s = EditingSession(image:try EditingTests.fixture(),canvas:CGSize(width:400,height:320),fullScreen:true,writer:ObjectWriter())
            s.style.color = .systemGreen; s.tool = tool
            s.document.append(EditingMark(tool:tool,points:[CGPoint(x:100,y:100),CGPoint(x:160,y:100)],style:EditingStyle(color:.systemRed)))
            let id = try #require(s.document.marks.first?.id)
            let view = EditingCanvasView(session:s,selectingForTranslation:false)
            let window = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; window.contentView = view
            defer { window.contentView = nil; window.close() }
            s.document.selectMark(id)
            await Task.yield(); view.needsLayout = true; view.layoutSubtreeIfNeeded()
            func descendants(_ v:NSView) -> [NSView] { [v]+v.subviews.flatMap(descendants) }
            let well = try #require(descendants(view).compactMap { $0 as? EditingNativeColorWell }.first)
            #expect(well.color.isEqual(NSColor.systemRed))
            well.onChange?(.systemBlue)
            #expect(s.document.marks.first?.style.color.isEqual(NSColor.systemBlue) == true)
            #expect(s.style.color.isEqual(NSColor.systemGreen))
            s.document.undo()
            #expect(s.document.marks.first?.id == id && s.document.marks.first?.style.color.isEqual(NSColor.systemRed) == true)
            #expect(!window.isVisible)
        }
    }

    @Test func continuousHiddenColorGestureAppliesEveryUpdateAndUndoesOnce() async throws {
        _ = NSApplication.shared
        let s = EditingSession(image:try EditingTests.fixture(),canvas:CGSize(width:400,height:320),fullScreen:true,writer:ObjectWriter())
        s.tool = .number; s.document.append(EditingMark(tool:.number,points:[CGPoint(x:100,y:100)],style:EditingStyle(color:.systemRed)))
        let id = try #require(s.document.marks.first?.id)
        let view = EditingCanvasView(session:s,selectingForTranslation:false)
        let window = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        s.selectObject(id); await Task.yield(); view.layoutSubtreeIfNeeded()
        func descendants(_ v:NSView) -> [NSView] { [v]+v.subviews.flatMap(descendants) }
        let well = try #require(descendants(view).compactMap { $0 as? EditingNativeColorWell }.first)
        well.beginColorEditing(); well.previewColor(.systemBlue); well.previewColor(.systemYellow); well.endColorEditing()
        #expect(s.document.marks.first?.style.color.isEqual(NSColor.systemYellow) == true)
        s.document.undo(); #expect(s.document.marks.first?.id == id && s.document.marks.first?.style.color.isEqual(NSColor.systemRed) == true)
        s.document.redo(); #expect(s.document.marks.first?.style.color.isEqual(NSColor.systemYellow) == true)
        s.document.append(EditingMark(tool:.number,points:[CGPoint(x:220,y:100)],style:EditingStyle(color:.systemGreen)))
        let nextID = try #require(s.document.marks.last?.id)
        s.selectObject(nextID); await Task.yield(); view.needsLayout = true; view.layoutSubtreeIfNeeded()
        // A queued action on the prior native well must not acquire the new target after view updates.
        well.previewColor(.systemPurple)
        #expect(s.document.marks.last?.style.color.isEqual(NSColor.systemGreen) == true)
        #expect(!window.isVisible)
    }

    @Test func movedAndRestyledObjectsExportTheirNewPixelsWithoutChangingSource() throws {
        let source = try EditingTests.fixture(), original = source.pngData
        for canvas in [CGSize(width:200,height:160),CGSize(width:400,height:320),CGSize(width:333.3,height:213.7)] {
            let sx = canvas.width/200, sy = canvas.height/160
            func point(_ x:CGFloat,_ y:CGFloat) -> CGPoint { CGPoint(x:x*sx,y:y*sy) }
            for tool in [EditingTool.number,.arrow] {
                let writer = ObjectWriter()
                let s = EditingSession(image:source,canvas:canvas,fullScreen:true,writer:writer)
                s.tool = tool
                let points = tool == .number ? [point(30,40)] : [point(20,40),point(70,40)]
                s.document.append(EditingMark(tool:tool,points:points,style:EditingStyle(color:NSColor(deviceRed:1,green:0,blue:0,alpha:1),width:6,fontSize:24*sx)))
                let before = try s.composite()
                let oldX = tool == .number ? 18 : 35
                let beforeBitmap = try #require(NSBitmapImageRep(data:before.pngData))
                let red = try #require(beforeBitmap.colorAt(x:oldX,y:40))
                #expect(red.redComponent > 0.9 && red.blueComponent < 0.1)
                var style = s.effectiveStyle; style.color = NSColor(deviceRed:0,green:0,blue:1,alpha:1)
                style.fontSize = 36*sx; style.width = 10
                #expect(s.setEffectiveStyle(style,context:s.captureStyleContext()))
                let pending = s.document.beginObjectEdit(.move), token = try #require(pending)
                _ = s.document.moveObject(token,totalCanvasDelta:CGSize(width:tool == .number ? 40*sx : 0,height:40*sy))
                _ = s.document.commitObjectEdit(token)
                let after = try s.composite(), bitmap = try #require(NSBitmapImageRep(data:after.pngData))
                let blue = try #require(bitmap.colorAt(x:tool == .number ? 54 : 35,y:80))
                #expect(blue.blueComponent > 0.9 && blue.redComponent < 0.1)
                let cleared = try #require(bitmap.colorAt(x:oldX,y:40))
                #expect(cleared.redComponent > 0.9 && cleared.greenComponent > 0.9 && cleared.blueComponent > 0.9)
                #expect(after.width == 200 && after.height == 160)
                s.copy(); #expect(writer.images.last == after)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
                defer { try? FileManager.default.removeItem(at:url) }
                s.save(to:url); #expect(try Data(contentsOf:url) == after.pngData)
                s.document.undo(); s.document.undo(); #expect(try s.composite() == before)
                s.document.redo(); s.document.redo(); #expect(try s.composite() == after)
                #expect(source.pngData == original)
            }
        }
    }

    @Test func objectEditsReuseTheSameBlurredSourceButCropOrBlurChangesInvalidateIt() throws {
        let s = EditingSession(image:try EditingTests.fixture(),canvas:CGSize(width:200,height:160),fullScreen:false,writer:ObjectWriter())
        s.document.select(from:CGPoint(x:20,y:20),to:CGPoint(x:180,y:140))
        s.document.append(EditingMark(tool:.blur,points:[CGPoint(x:80,y:60)]))
        s.tool = .arrow; s.document.append(EditingMark(tool:.arrow,points:[CGPoint(x:20,y:20),CGPoint(x:60,y:40)]))
        let first = try #require(s.blurredSourceImage())
        var style = s.effectiveStyle; style.color = .systemBlue
        _ = s.setEffectiveStyle(style,context:s.captureStyleContext())
        #expect(s.blurredSourceImage() === first)
        let pending = s.document.beginObjectEdit(.move); let token = try #require(pending)
        _ = s.document.moveObject(token,totalCanvasDelta:CGSize(width:3,height:2))
        #expect(s.blurredSourceImage() === first)
        s.document.cancelObjectEdit(); #expect(s.blurredSourceImage() === first)
        s.document.undo(); #expect(s.blurredSourceImage() === first)
        s.document.moveSelection(by:CGSize(width:1,height:1))
        let moved = try #require(s.blurredSourceImage()); #expect(moved !== first)
        s.document.append(EditingMark(tool:.blur,points:[CGPoint(x:30,y:30)]))
        #expect(s.blurredSourceImage() !== moved)
    }

}
@MainActor private final class ObjectWriter: ImageOutputWriting {
    var outcome:CopyOutcome = .failed
    var images:[RasterImage] = []
    func copyImage(_ image:RasterImage) -> CopyOutcome { images.append(image); return outcome }
}
