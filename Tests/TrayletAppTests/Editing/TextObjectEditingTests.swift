import AppKit
import Testing
import TrayletCore
@testable import TrayletApp

@MainActor struct TextObjectEditingTests {
    @Test func doubleClickReopensExistingTextAndCommitsOneReplacement() throws {
        let f = try TextObjectFixture(); defer { f.close() }
        f.session.document.append(EditingMark(tool:.text,points:[CGPoint(x:30,y:35)],text:"Original 原文"))
        let original = try #require(f.session.document.marks.first)
        f.canvas.mouseDown(with:f.mouse(.leftMouseDown,CGPoint(x:40,y:45),clicks:2))
        let editor = try #require(f.window.firstResponder as? NSTextView)
        #expect(editor.string == "Original 原文")
        editor.string = "  Updated 更新\nsecond line  "
        editor.keyDown(with:f.key(36,flags:.command))
        #expect(f.session.document.marks.count == 1)
        #expect(f.session.document.marks.first?.id == original.id)
        #expect(f.session.document.marks.first?.text == "  Updated 更新\nsecond line  ")
        f.session.document.undo(); #expect(f.session.document.marks == [original])
        f.session.document.redo(); #expect(f.session.document.marks.first?.text == "  Updated 更新\nsecond line  ")
        #expect(!f.window.isVisible)
    }
    @Test func selectedTextMovePreservesWrappingAndStyleEditsPreserveDefaults() async throws {
        let f = try TextObjectFixture(); defer { f.close() }
        let s = f.session
        s.style.fontSize = 18
        s.document.append(EditingMark(tool:.text,points:[CGPoint(x:230,y:40)],style:EditingStyle(color:.red,fontSize:24),text:"AA AA AA AA AA AA"))
        let original = try #require(s.document.marks.first)
        let beforeLines = EditingTextLayout.lines(original,in:CGRect(origin:.zero,size:s.document.canvas))
        f.canvas.mouseDown(with:f.mouse(.leftMouseDown,CGPoint(x:240,y:50)))
        f.canvas.mouseDragged(with:f.mouse(.leftMouseDragged,CGPoint(x:190,y:60)))
        f.canvas.mouseUp(with:f.mouse(.leftMouseUp,CGPoint(x:190,y:60)))
        let moved = try #require(s.document.marks.first)
        #expect(moved.id == original.id && moved.points == [CGPoint(x:180,y:50)])
        let afterLines = EditingTextLayout.lines(moved,in:CGRect(origin:.zero,size:s.document.canvas))
        #expect(afterLines.count == beforeLines.count)
        #expect(afterLines.map(\.width) == beforeLines.map(\.width))
        var changed = s.effectiveStyle; changed.fontSize = 36; changed.color = .blue
        #expect(s.setEffectiveStyle(changed,context:s.captureStyleContext()))
        #expect(s.document.marks.first?.style.fontSize == 36)
        #expect(s.style.fontSize == 18)
        s.document.undo(); #expect(s.document.marks.first == moved)
        s.document.undo(); #expect(s.document.marks.first == original)
    }

    @Test func draftsCancelDeleteAndRejectLateHandlesWithoutLosingOriginalText() async throws {
        let f = try TextObjectFixture(); defer { f.close() }
        let s = f.session
        s.document.append(EditingMark(tool:.text,points:[CGPoint(x:30,y:35)],text:"Original 原文"))
        let original = try #require(s.document.marks.first)
        func open() throws -> NSTextView {
            f.canvas.mouseDown(with:f.mouse(.leftMouseDown,CGPoint(x:40,y:45),clicks:2))
            return try #require(f.window.firstResponder as? NSTextView)
        }
        let editor = try open()
        editor.insertText(" draft",replacementRange:NSRange(location:editor.string.utf16.count,length:0))
        editor.undoManager?.undo()
        #expect(s.document.marks == [original])
        editor.string = "discard me"; editor.keyDown(with:f.key(53))
        #expect(s.document.marks == [original] && !s.isEditingText)
        let next = try open(); editor.string = "late"; editor.keyDown(with:f.key(36,flags:.command))
        #expect(next.superview != nil && s.document.marks == [original])
        next.setMarkedText("拼",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        #expect(!f.canvas.finishText() && !s.prepareOutput())
        NotificationCenter.default.post(name:NSWindow.didResignKeyNotification,object:f.window)
        #expect(!s.isEditingText && s.document.marks == [original] && s.message.isEmpty)
        next.unmarkText(); next.keyDown(with:f.key(36,flags:.command)); #expect(s.document.marks == [original])
        let empty = try open(); empty.string = " \n\t "; #expect(f.canvas.finishText())
        #expect(s.document.marks.isEmpty)
        s.document.undo(); #expect(s.document.marks == [original]); s.document.redo(); #expect(s.document.marks.isEmpty)
        f.canvas.mouseDown(with:f.mouse(.leftMouseDown,CGPoint(x:40,y:45)))
        let fresh = try #require(f.window.firstResponder as? NSTextView); fresh.string = "new draft"; fresh.keyDown(with:f.key(53))
        #expect(s.document.marks.isEmpty && !s.isEditingText)
        s.document.undo(); #expect(s.document.marks == [original])
        let stale = try open(); s.tool = .arrow; await Task.yield(); await Task.yield()
        #expect(stale.superview == nil && !s.isEditingText)
        stale.string = "should not apply"; stale.keyDown(with:f.key(36,flags:.command))
        #expect(s.document.marks == [original])
    }

    @Test func activeDraftIsCoveredByRedactionAndNativeOptionsAreDisabled() async throws {
        let f = try TextObjectFixture(); defer { f.close() }
        let s = f.session
        s.document.append(EditingMark(tool:.text,points:[CGPoint(x:30,y:35)],style:EditingStyle(color:.red,fontSize:40),text:"MMMM"))
        s.document.append(EditingMark(tool:.redaction,points:[CGPoint(x:20,y:30),CGPoint(x:250,y:100)]))
        f.canvas.mouseDown(with:f.mouse(.leftMouseDown,CGPoint(x:40,y:45),clicks:2))
        let editor = try #require(f.window.firstResponder as? NSTextView); editor.string = "MMMMMMMM"
        await Task.yield(); f.canvas.needsLayout = true; f.canvas.layoutSubtreeIfNeeded()
        func descendants(_ v:NSView) -> [NSView] { [v]+v.subviews.flatMap(descendants) }
        let well = try #require(descendants(f.canvas).compactMap { $0 as? EditingNativeColorWell }.first)
        let field = try #require(descendants(f.canvas).compactMap { $0 as? EditingStyleNativeNumberField }.first)
        #expect(!well.isEnabled && !field.isEnabled)
        let bitmap = try #require(f.canvas.bitmapImageRepForCachingDisplay(in:f.canvas.bounds)); f.canvas.cacheDisplay(in:f.canvas.bounds,to:bitmap)
        let scale = CGFloat(bitmap.pixelsWide)/f.canvas.bounds.width
        var nonBlack = 0
        for y in Int(40*scale)..<Int(85*scale) { for x in Int(35*scale)..<Int(200*scale) {
            let color = try #require(bitmap.colorAt(x:x,y:y))
            if color.redComponent > 0.01 || color.greenComponent > 0.01 || color.blueComponent > 0.01 { nonBlack += 1 }
        } }
        #expect(nonBlack == 0)
        #expect(f.canvas.hitTest(CGPoint(x:40,y:45)) === editor)
        f.canvas.cancelText(); #expect(s.document.marks.first?.text == "MMMM")
    }

    @Test func textMovementKeepsAVisibleLineAndClippedZeroMotionDoesNotJump() throws {
        let f = try TextObjectFixture(); defer { f.close() }
        let s = f.session, bounds = CGRect(origin:.zero,size:s.document.canvas)
        s.document.append(EditingMark(tool:.text,points:[CGPoint(x:30,y:35)],style:EditingStyle(color:.red,fontSize:96),text:"    X"))
        let start = s.document.beginObjectEdit(.move), token = try #require(start)
        _ = s.document.moveObject(token,totalCanvasDelta:CGSize(width:2000,height:2000)); _ = s.document.commitObjectEdit(token)
        let moved = try #require(s.document.marks.first)
        #expect(!EditingTextLayout.lines(moved,in:bounds).isEmpty)
        let bitmap = try #require(NSBitmapImageRep(data:s.composite().pngData))
        var redPixels = 0
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
            let c = try #require(bitmap.colorAt(x:x,y:y))
            if c.redComponent > 0.7 && c.greenComponent < 0.5 { redPixels += 1 }
        } }
        #expect(redPixels > 5)
        #expect(moved.points[0].x < bounds.maxX && moved.points[0].y < bounds.maxY)
        s.document.append(EditingMark(tool:.text,points:[CGPoint(x:-12,y:-5)],text:"Clipped"))
        let clipped = try #require(s.document.marks.last), pending = s.document.beginObjectEdit(.move), zero = try #require(pending)
        _ = s.document.moveObject(zero,totalCanvasDelta:.zero); _ = s.document.commitObjectEdit(zero)
        #expect(s.document.marks.last == clipped)
    }

    @Test func multilineTextMovesBySourcePixelsWithoutReflowOrChangingTheSource() throws {
        for canvas in [CGSize(width:200,height:160),CGSize(width:400,height:320),CGSize(width:333.3,height:213.7)] {
            let f = try TextObjectFixture(canvas:canvas); defer { f.close() }
            let s = f.session, sx = canvas.width/200, sy = canvas.height/160, originalPNG = s.image.pngData
            s.document.append(EditingMark(tool:.text,points:[CGPoint(x:15*sx,y:20*sy)],style:EditingStyle(color:.red,fontSize:12*sx),text:"AB 中英\nCD words",textWidth:65*sx))
            let original = try s.composite(), before = try #require(NSBitmapImageRep(data:original.pngData))
            let pending = s.document.beginObjectEdit(.move), token = try #require(pending)
            _ = s.document.moveObject(token,totalCanvasDelta:CGSize(width:10*sx,height:10*sy)); _ = s.document.commitObjectEdit(token)
            let moved = try s.composite(), after = try #require(NSBitmapImageRep(data:moved.pngData))
            var differences = 0, ink = 0
            for y in 0..<125 { for x in 0..<85 {
                let a = try #require(before.colorAt(x:x,y:y)), b = try #require(after.colorAt(x:x+10,y:y+10))
                if abs(a.greenComponent-b.greenComponent) > 0.02 { differences += 1 }
                if a.greenComponent < 0.5 { ink += 1 }
            } }
            #expect(ink > 20 && differences == 0)
            #expect(s.image.pngData == originalPNG && moved.width == 200 && moved.height == 160)
            s.document.undo(); #expect(try s.composite() == original)
            s.document.redo(); #expect(try s.composite() == moved)
        }
    }

    @Test func narrowNativeTextStylesTargetTheSelectedObjectAndEnterReopensIt() async throws {
        let f = try TextObjectFixture(canvas:CGSize(width:180,height:320)); defer { f.close() }
        let s = f.session; s.style.fontSize = 18
        s.document.append(EditingMark(tool:.text,points:[CGPoint(x:20,y:50)],style:EditingStyle(color:.red,fontSize:24),text:"Ab 中"))
        let id = try #require(s.document.selectedMarkID)
        await Task.yield(); f.canvas.needsLayout = true; f.canvas.layoutSubtreeIfNeeded()
        func descendants(_ v:NSView) -> [NSView] { [v]+v.subviews.flatMap(descendants) }
        let field = try #require(descendants(f.canvas).compactMap { $0 as? EditingStyleNativeNumberField }.first)
        #expect(field.doubleValue == 24 && f.canvas.barFrames.options.width <= 172)
        #expect(f.window.makeFirstResponder(field))
        let valueEditor = try #require(field.currentEditor() as? NSTextView)
        valueEditor.selectAll(nil); valueEditor.insertText("37",replacementRange:valueEditor.selectedRange()); valueEditor.keyDown(with:f.key(36))
        f.window.makeFirstResponder(f.canvas); await Task.yield()
        #expect(s.document.selectedMark?.style.fontSize == 37 && s.style.fontSize == 18)
        let well = try #require(descendants(f.canvas).compactMap { $0 as? EditingNativeColorWell }.first)
        well.beginColorEditing(); well.previewColor(.blue); well.endColorEditing()
        #expect(s.document.selectedMark?.style.color.isEqual(NSColor.blue) == true && s.document.selectedMarkID == id)
        f.canvas.keyDown(with:f.key(36)); let editor = try #require(f.window.firstResponder as? NSTextView)
        #expect(editor.string == "Ab 中" && editor.font?.pointSize == 37)
        editor.setSelectedRange(NSRange(location:editor.string.utf16.count,length:0)); editor.keyDown(with:f.key(36))
        #expect(editor.string.hasSuffix("\n") && s.document.marks.count == 1)
        editor.keyDown(with:f.key(36,flags:.command)); #expect(!s.isEditingText && s.document.marks.count == 1)
    }

    @Test func longMultilingualDraftKeepsCompleteTextAndDoesNotPickEmptyCropArea() throws {
        let f = try TextObjectFixture(); defer { f.close() }
        let s = f.session
        let content = String(repeating:"中文 English line\n",count:2000)
        s.document.append(EditingMark(tool:.text,points:[CGPoint(x:30,y:35)],text:content,textWidth:140))
        let original = try #require(s.document.marks.first)
        f.canvas.mouseDown(with:f.mouse(.leftMouseDown,CGPoint(x:300,y:45)))
        let fresh = try #require(f.window.firstResponder as? NSTextView)
        #expect(fresh.string.isEmpty); fresh.keyDown(with:f.key(53)); #expect(s.document.marks == [original])
        f.canvas.mouseDown(with:f.mouse(.leftMouseDown,CGPoint(x:40,y:45),clicks:2))
        let editor = try #require(f.window.firstResponder as? NSTextView)
        #expect(editor.string == content)
        editor.string += "尾行"; editor.keyDown(with:f.key(36,flags:.command))
        #expect(s.document.marks.count == 1 && s.document.marks.first?.text == content+"尾行")
        s.document.undo(); #expect(s.document.marks == [original])
    }

    @Test func activeTextDraftCompositesLaterTransparentAndAntialiasedMarksOnlyOnce() async throws {
        for zoomed in [false,true] {
            let size = zoomed ? CGSize(width:333.3,height:213.7) : CGSize(width:400,height:320)
            let f = try TextObjectFixture(canvas:size); defer { f.close() }
            let s = f.session, sx = size.width/400, sy = size.height/320
            func p(_ x:CGFloat,_ y:CGFloat) -> CGPoint { CGPoint(x:x*sx,y:y*sy) }
            // Earlier translucent paint must remain behind the draft, later paint spans its right edge.
            s.document.append(EditingMark(tool:.rectangle,points:[p(20,65),p(210,135)],style:EditingStyle(color:NSColor.red.withAlphaComponent(0.2),filled:true)))
            s.document.append(EditingMark(tool:.text,points:[p(30,35)],style:EditingStyle(fontSize:20*sx),text:"A",textWidth:80*sx))
            let id = try #require(s.document.marks.last?.id)
            s.document.append(EditingMark(tool:.rectangle,points:[p(55,72),p(190,128)],style:EditingStyle(color:NSColor.blue.withAlphaComponent(0.35),filled:true)))
            s.document.append(EditingMark(tool:.arrow,points:[p(60,90),p(180,115)],style:EditingStyle(color:.systemGreen,width:1.3)))
            s.document.append(EditingMark(tool:.text,points:[p(150,76)],style:EditingStyle(color:.black,fontSize:11),text:"Edge"))
            s.document.append(EditingMark(tool:.highlight,points:[p(25,70),p(205,130)],style:EditingStyle(color:.yellow)))
            s.document.append(EditingMark(tool:.blur,points:[p(200,100)],style:EditingStyle(brushSize:15)))
            s.document.append(EditingMark(tool:.redaction,points:[.zero,p(8,8)]))
            s.selectObject(id)
            if zoomed {
                s.viewport.fit(CGRect(x:0,y:0,width:size.width/1.25,height:size.height/1.25),in:CGRect(origin:.zero,size:size),canvas:size)
                s.viewport.pan(by:CGSize(width:7,height:3),in:f.canvas.bounds,canvas:size)
            }
            func capture() async throws -> NSBitmapImageRep {
                await Task.yield(); f.canvas.needsLayout = true; f.canvas.layoutSubtreeIfNeeded(); f.canvas.needsDisplay = true
                let image = try #require(f.canvas.bitmapImageRepForCachingDisplay(in:f.canvas.bounds))
                f.canvas.cacheDisplay(in:f.canvas.bounds,to:image); return image
            }
            let before = try await capture(), exported = try s.composite()
            // Exclude the edited short text's selection outline, which intentionally disappears in a draft.
            let roi = s.viewport.viewRect(CGRect(x:60*sx,y:68*sy,width:148*sx,height:66*sy))
            func difference(_ image:NSBitmapImageRep) throws -> Int {
                let scale = CGFloat(image.pixelsWide)/f.canvas.bounds.width
                var count = 0
                for y in Int(ceil(roi.minY*scale))..<Int(floor(roi.maxY*scale)) {
                    for x in Int(ceil(roi.minX*scale))..<Int(floor(roi.maxX*scale)) {
                        let a = try #require(before.colorAt(x:x,y:y)), b = try #require(image.colorAt(x:x,y:y))
                        if abs(a.redComponent-b.redComponent) > 0.005 || abs(a.greenComponent-b.greenComponent) > 0.005 || abs(a.blueComponent-b.blueComponent) > 0.005 {
                            count += 1
                        }
                    }
                }
                // The crop's top-left handle must stay above the final black layer too.
                let corner = s.viewport.viewPoint(.zero)
                let x = Int((corner.x+1)*scale), y = Int((corner.y+1)*scale)
                let a = try #require(before.colorAt(x:x,y:y)), b = try #require(image.colorAt(x:x,y:y))
                if abs(a.redComponent-b.redComponent) > 0.005 || abs(a.greenComponent-b.greenComponent) > 0.005 || abs(a.blueComponent-b.blueComponent) > 0.005 { count += 1 }
                return count
            }
            let click = s.viewport.viewPoint(p(34,42))
            f.canvas.mouseDown(with:f.mouse(.leftMouseDown,click,clicks:2))
            let editor = try #require(f.window.firstResponder as? NSTextView)
            #expect(editor.string == "A")
            #expect(f.canvas.hitTest(click) === editor)
            let draft = try await capture(), draftDifferences = try difference(draft); #expect(draftDifferences == 0)
            #expect(f.canvas.finishText()); let committed = try await capture(); #expect(try difference(committed) == 0)
            #expect(try s.composite() == exported)
            f.canvas.mouseDown(with:f.mouse(.leftMouseDown,click,clicks:2))
            let next = try #require(f.window.firstResponder as? NSTextView)
            editor.string = "stale"; editor.keyDown(with:f.key(36,flags:.command))
            #expect(next.superview != nil && f.window.firstResponder === next)
            next.keyDown(with:f.key(53)); let cancelled = try await capture(); #expect(try difference(cancelled) == 0)
            #expect(try s.composite() == exported && !s.isEditingText)
        }
    }

}

@MainActor private final class TextObjectFixture {
    let session:EditingSession
    let canvas:EditingCanvasView
    let window:NSWindow
    init(canvas size:CGSize = CGSize(width:400,height:320)) throws {
        _ = NSApplication.shared
        session = EditingSession(image:try EditingTests.fixture(),canvas:size,fullScreen:true,writer:TextObjectWriter())
        session.tool = .text
        canvas = EditingCanvasView(session:session,selectingForTranslation:false)
        window = NSWindow(contentRect:canvas.bounds,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
    }
    func close() { window.contentView = nil; window.close() }
    func mouse(_ type:NSEvent.EventType,_ point:CGPoint,clicks:Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:clicks,pressure:1)!
    }
    func key(_ code:UInt16,flags:NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:code == 36 ? "\r" : "",charactersIgnoringModifiers:code == 36 ? "\r" : "",isARepeat:false,keyCode:code)!
    }
}
@MainActor private final class TextObjectWriter: ImageOutputWriting {
    func copyImage(_ image:RasterImage) -> CopyOutcome { .failed }
}
