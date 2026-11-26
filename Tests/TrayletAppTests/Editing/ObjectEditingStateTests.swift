import AppKit
import Testing
import TrayletCore
@testable import TrayletApp

@MainActor struct ObjectEditingStateTests {
    @Test func styleTransactionsKeepIdentityAndDefaultsAndRejectStaleCallbacks() throws {
        for tool in [EditingTool.number,.arrow] {
            let s = EditingSession(image:try EditingTests.fixture(),canvas:CGSize(width:400,height:320),fullScreen:true,writer:StateWriter())
            s.style = EditingStyle(color:.systemGreen,width:3,fontSize:19); s.tool = tool
            s.document.append(EditingMark(tool:tool,points:[CGPoint(x:50,y:50),CGPoint(x:80,y:70)],style:EditingStyle(color:.systemRed,width:4,fontSize:24)))
            let first = try #require(s.document.marks.first)
            s.document.append(EditingMark(tool:tool,points:[CGPoint(x:180,y:100),CGPoint(x:220,y:140)]))
            let second = try #require(s.document.marks.last)
            s.selectObject(first.id)
            let token = try #require(s.beginStyleEditing(context:s.captureStyleContext()))
            for value in [CGFloat(8),12,16] {
                var style = s.effectiveStyle; style.color = .systemBlue; style.width = value; style.fontSize = value+20
                #expect(s.updateStyle(style,token:token))
            }
            s.finishStyleEditing(token)
            let edited = s.document.marks[0]
            #expect(edited.id == first.id && edited.points == first.points && edited.number == first.number)
            #expect(s.document.marks[1] == second && s.style == EditingStyle(color:.systemGreen,width:3,fontSize:19))
            s.document.undo(); #expect(s.document.marks[0] == first)
            s.document.redo(); #expect(s.document.marks[0] == edited)
            s.selectObject(first.id)
            let oldContext = s.captureStyleContext(), cancelled = try #require(s.beginStyleEditing(context:s.captureStyleContext()))
            var changed = s.effectiveStyle; changed.color = .systemYellow
            #expect(s.updateStyle(changed,token:cancelled)); s.cancelStyleEditing(cancelled)
            #expect(s.document.marks[0] == edited)
            s.selectObject(second.id)
            #expect(!s.setEffectiveStyle(changed,context:oldContext))
            #expect(!s.updateStyle(changed,token:cancelled))
            let active = try #require(s.beginStyleEditing(context:s.captureStyleContext()))
            s.cancelStyleEditing(cancelled)
            #expect(s.isStyleEditing(active))
            s.document.undo() // Cancels this active preview, without popping an earlier committed edit.
            #expect(!s.updateStyle(changed,token:active))
            let fresh = try #require(s.beginStyleEditing(context:s.captureStyleContext()))
            #expect(s.updateStyle(changed,token:fresh)); s.finishStyleEditing(fresh)
            #expect(s.document.marks[0] == edited && s.document.marks[1].style.color.isEqual(NSColor.systemYellow))
            s.document.undo(); s.selectObject(first.id)
            var branch = s.effectiveStyle; branch.color = .systemPurple
            #expect(s.setEffectiveStyle(branch,context:s.captureStyleContext()) && !s.document.canRedo)
            #expect(s.document.marks.map(\.id) == [first.id,second.id])
        }
    }

    @Test func restartingDefaultStyleGestureUsesFreshContextAndCancellationRestoresIt() throws {
        let s = EditingSession(image:try EditingTests.fixture(),canvas:CGSize(width:400,height:320),fullScreen:true,writer:StateWriter())
        s.tool = .number
        let first = try #require(s.beginStyleEditing(context:s.captureStyleContext()))
        var blue = s.style; blue.color = .systemBlue
        #expect(s.updateStyle(blue,token:first))
        let second = try #require(s.beginStyleEditing(context:s.captureStyleContext()))
        var yellow = s.style; yellow.color = .systemYellow
        #expect(s.updateStyle(yellow,token:second))
        s.cancelStyleEditing(second)
        #expect(s.style == blue && s.document.marks.isEmpty && !s.document.canUndo)
        #expect(!s.updateStyle(yellow,token:first))
    }

    @Test func clippedObjectsKeepZeroDeltaAndMovesUseSourcePixelStepsWithoutChangingZOrder() throws {
        for tool in [EditingTool.number,.arrow] {
            for size in [CGSize(width:200,height:160),CGSize(width:400,height:320),CGSize(width:333.3,height:213.7)] {
                var d = EditingDocument(canvas:size,imageSize:CGSize(width:200,height:160),fullScreen:true)
                d.append(EditingMark(tool:.rectangle,points:[.zero,CGPoint(x:20,y:20)]))
                d.append(EditingMark(tool:tool,points:tool == .number ? [CGPoint(x:0,y:10)] : [CGPoint(x:-3,y:10),CGPoint(x:30,y:20)]))
                let original = d.marks, next = d.nextNumber
                let pending = d.beginObjectEdit(.move), token = try #require(pending)
                let noMove = d.moveObject(token,totalCanvasDelta:.zero); #expect(!noMove && d.marks == original)
                let outward = d.moveObject(token,totalCanvasDelta:CGSize(width:-100,height:0)); #expect(!outward && d.marks == original)
                _ = d.moveObject(token,totalCanvasDelta:CGSize(width:size.width/200*0.2,height:0))
                #expect(d.marks == original)
                _ = d.moveObject(token,totalCanvasDelta:CGSize(width:size.width/200,height:size.height/160*10))
                #expect(abs((d.marks[1].points[0].x-original[1].points[0].x)*200/size.width-1) < 0.000001)
                #expect(abs((d.marks[1].points[0].y-original[1].points[0].y)*160/size.height-10) < 0.000001)
                let committed = d.commitObjectEdit(token); #expect(committed)
                #expect(d.marks.map(\.id) == original.map(\.id) && d.nextNumber == next)
                d.undo(); #expect(d.marks == original)
                d.redo(); #expect(d.marks[0] == original[0])
                d.selectMark(original[1].id)
                let cancelPending = d.beginObjectEdit(.move), cancelToken = try #require(cancelPending)
                let before = d.marks
                _ = d.moveObject(cancelToken,totalCanvasDelta:CGSize(width:10,height:10)); d.cancelObjectEdit()
                #expect(d.marks == before)
                let late = d.moveObject(cancelToken,totalCanvasDelta:CGSize(width:20,height:20)); #expect(!late)
            }
        }
    }

    @Test func hiddenMoveCancellationNudgingAndOutputRemainConsistentWithViewport() throws {
        for tool in [EditingTool.number,.arrow] {
            let f = try ObjectFixture(tool:tool,canvas:CGSize(width:400,height:320))
            defer { f.close() }
            let s = f.session, view = f.view
            s.document.select(from:CGPoint(x:40,y:40),to:CGPoint(x:360,y:280))
            s.document.append(EditingMark(tool:tool,points:tool == .number ? [CGPoint(x:60,y:60)] : [CGPoint(x:40,y:60),CGPoint(x:100,y:60)]))
            let id = try #require(s.document.marks.last?.id)
            s.viewport.fit(s.document.selection!,in:CGRect(x:20,y:20,width:360,height:220),canvas:s.document.canvas)
            s.viewport.pan(by:CGSize(width:12,height:8),in:view.bounds,canvas:s.document.canvas)
            let initial = s.document.marks, crop = s.document.selection, output = try s.composite()
            let start = s.viewport.viewPoint(CGPoint(x:100,y:100)), end = s.viewport.viewPoint(CGPoint(x:112,y:106))
            for loss in 0..<3 {
                view.mouseDown(with:f.mouse(.leftMouseDown,start)); view.mouseDragged(with:f.mouse(.leftMouseDragged,end))
                #expect(s.document.marks != initial && !s.copy() && f.writer.images.isEmpty)
                if loss == 0 { view.keyDown(with:f.key(53)) }
                else { NotificationCenter.default.post(name:loss == 1 ? NSWindow.didResignKeyNotification : NSApplication.didResignActiveNotification,object:loss == 1 ? f.window : NSApp) }
                view.mouseUp(with:f.mouse(.leftMouseUp,end))
                #expect(s.document.marks == initial && s.document.selectedMarkID == id && s.message.isEmpty)
                #expect(try s.composite() == output)
            }
            view.mouseDown(with:f.mouse(.leftMouseDown,start)); view.mouseUp(with:f.mouse(.leftMouseUp,start))
            view.keyDown(with:f.key(124)); view.keyDown(with:f.key(125,flags:.shift))
            #expect(s.document.marks[0].points[0] == CGPoint(x:initial[0].points[0].x+2,y:initial[0].points[0].y+20))
            #expect(s.document.selection == crop)
            view.keyDown(with:f.key(124,flags:.command))
            #expect(s.document.selection?.width == crop!.width+2)
            s.selectObject(nil); view.keyDown(with:f.key(123))
            #expect(s.document.selection?.minX == crop!.minX-2)
            #expect(!f.window.isVisible)
        }
    }

    @Test func hiddenCompactFieldsEditSelectedObjectsAndRetainDefaults() async throws {
        for tool in [EditingTool.number,.arrow] {
            let f = try ObjectFixture(tool:tool,canvas:CGSize(width:180,height:320)); defer { f.close() }
            let s = f.session
            s.document.append(EditingMark(tool:tool,points:[CGPoint(x:50,y:80),CGPoint(x:100,y:80)]))
            let id = try #require(s.document.marks.first?.id), defaults = s.style
            s.selectObject(id); await Task.yield(); f.view.needsLayout = true; f.view.layoutSubtreeIfNeeded()
            let options = try #require(f.view.subviews.dropFirst().first)
            #expect(options.intrinsicContentSize.width <= 172 && f.view.bounds.contains(options.frame))
            let field = try #require(f.descendants(options).compactMap { $0 as? NSTextField }.first { $0.isEditable })
            #expect(field.doubleValue == (tool == .number ? 24 : 4))
            #expect(f.window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.selectAll(nil); editor.insertText(tool == .number ? "37" : "12",replacementRange:editor.selectedRange())
            editor.keyDown(with:f.key(36,text:"\r")); f.window.makeFirstResponder(f.view)
            await Task.yield()
            #expect(s.document.selectedMarkID == id)
            #expect(tool == .number ? s.document.selectedMark?.style.fontSize == 37 : s.document.selectedMark?.style.width == 12)
            #expect(s.style == defaults && !f.window.isVisible)
        }
    }
}

@MainActor private final class StateWriter: ImageOutputWriting {
    var images:[RasterImage] = []
    func copyImage(_ image:RasterImage) -> CopyOutcome { images.append(image); return .failed }
}
@MainActor private final class ObjectFixture {
    let writer = StateWriter()
    let session:EditingSession
    let view:EditingCanvasView
    let window:NSWindow
    init(tool:EditingTool,canvas:CGSize) throws {
        _ = NSApplication.shared
        session = EditingSession(image:try EditingTests.fixture(),canvas:canvas,fullScreen:true,writer:writer); session.tool = tool
        view = EditingCanvasView(session:session,selectingForTranslation:false)
        window = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = view
    }
    func close() { window.contentView = nil; window.close() }
    func descendants(_ v:NSView) -> [NSView] { [v]+v.subviews.flatMap(descendants) }
    func mouse(_ type:NSEvent.EventType,_ p:CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with:type,location:view.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,
            context:nil,eventNumber:0,clickCount:1,pressure:1)!
    }
    func key(_ code:UInt16,text:String = "",flags:NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,
            context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!
    }
}
