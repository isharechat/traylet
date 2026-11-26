import AppKit
import Testing
import TrayletCore
@testable import TrayletApp

@MainActor struct PreciseEditingTests {
    @Test func tinyAndSingleAxisDragsCoverSourcePixelsAndClicksDoNotSelect() throws {
        for canvas in [CGSize(width:200,height:160), CGSize(width:100,height:80), CGSize(width:333.3,height:213.7)] {
            let s = EditingSession(image:try EditingTests.fixture(),canvas:canvas,fullScreen:false,writer:PreciseWriter())
            let sx = canvas.width/200, sy = canvas.height/160
            let start = CGPoint(x:20*sx,y:30*sy)
            for delta in [CGSize(width:sx,height:sy),CGSize(width:0.1*sx,height:0),CGSize(width:0,height:-0.1*sy)] {
                s.document.selectLive(from:start,to:CGPoint(x:start.x+delta.width,y:start.y+delta.height))
                let kept = s.document.finishSelection(); #expect(kept)
                let output = try s.composite()
                #expect(output.width == 1 && output.height == 1)
                #expect(s.document.pixelBounds(imageSize:CGSize(width:200,height:160))?.size == CGSize(width:1,height:1))
            }
            s.document.selectLive(from:start,to:start)
            let kept = s.document.finishSelection(); #expect(!kept && s.document.selection == nil)
        }
    }
    @Test func tinySelectionHasReachableHandlesAndCenterMoveWithoutResizeJump() throws {
        _ = NSApplication.shared
        let s = EditingSession(image:try EditingTests.fixture(),canvas:CGSize(width:400,height:320),fullScreen:false,writer:PreciseWriter())
        s.document.select(from:CGPoint(x:100,y:100),to:CGPoint(x:102,y:102))
        let view = EditingCanvasView(session:s,selectingForTranslation:false)
        let window = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        func mouse(_ type:NSEvent.EventType,_ p:CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:view.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,
                context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        #expect(view.cursor(at:CGPoint(x:101,y:101)) == .openHand)
        // 32pt interaction frame centered around the 2pt pixel crop; the visible crop stays 1×1px.
        let east = CGPoint(x:117,y:101)
        #expect(view.cursor(at:east) != .arrow)
        view.mouseDown(with:mouse(.leftMouseDown,east))
        view.mouseDragged(with:mouse(.leftMouseDragged,east))
        #expect(s.document.selection == CGRect(x:100,y:100,width:2,height:2))
        view.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:119,y:101)))
        view.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:119,y:101)))
        #expect(s.document.pixelBounds(imageSize:CGSize(width:200,height:160)) == CGRect(x:50,y:50,width:2,height:1))
        view.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:102,y:101)))
        for step in 1...4 { view.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:102+CGFloat(step)*0.5,y:101))) }
        view.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:104,y:101)))
        #expect(s.document.pixelBounds(imageSize:CGSize(width:200,height:160)) == CGRect(x:51,y:50,width:2,height:1))
        #expect(!window.isVisible)
    }

    @Test func pixelGridCoversFractionalEdgesAndNudgesNeverGrowTheCrop() throws {
        let imageSize = CGSize(width:200,height:160)
        let canvas = CGSize(width:333.3,height:213.7)
        var d = EditingDocument(canvas:canvas,imageSize:imageSize)
        func point(_ x:CGFloat,_ y:CGFloat) -> CGPoint { CGPoint(x:x*canvas.width/200,y:y*canvas.height/160) }
        d.select(from:point(20.2,30.7),to:point(21.1,31.2))
        #expect(d.pixelBounds(imageSize:imageSize) == CGRect(x:20,y:30,width:2,height:2))
        d.append(EditingMark(tool:.rectangle,points:[.zero,CGPoint(x:1,y:1)]))
        for _ in 0..<50 { d.nudgeSelection(.right,imageSize:imageSize); d.nudgeSelection(.down,imageSize:imageSize) }
        #expect(d.pixelBounds(imageSize:imageSize) == CGRect(x:70,y:80,width:2,height:2))
        d.nudgeSelection(.left,imageSize:imageSize,accelerated:true,resizing:true)
        d.nudgeSelection(.up,imageSize:imageSize,accelerated:true,resizing:true)
        #expect(d.pixelBounds(imageSize:imageSize) == CGRect(x:70,y:80,width:1,height:1))
        let version = d.renderVersion
        d.nudgeSelection(.left,imageSize:imageSize,resizing:true)
        #expect(d.renderVersion == version)
        #expect(d.marks.first?.points == [.zero,CGPoint(x:1,y:1)])
        let output = try EditingRenderer.render(EditingTests.fixture(),document:d)
        #expect(output.width == 1 && output.height == 1)
        d.undo(); #expect(d.marks.isEmpty); d.redo(); #expect(d.marks.count == 1)
        for (a,b,expected) in [
            (point(200,160),point(199.9,159.9),CGRect(x:199,y:159,width:1,height:1)),
            (point(200,160),point(199.9,160),CGRect(x:199,y:159,width:1,height:1)),
            (point(19.9,29.9),point(20.1,30.1),CGRect(x:19,y:29,width:2,height:2)),
            (point(20.1,30.1),point(19.9,29.9),CGRect(x:19,y:29,width:2,height:2)),
            (point(0,0),point(-1,-1),CGRect(x:0,y:0,width:1,height:1)),
            (point(20-1e-10,30+1e-10),point(21+1e-10,31-1e-10),CGRect(x:20,y:30,width:1,height:1))
        ] {
            d.select(from:a,to:b); #expect(d.pixelBounds(imageSize:imageSize) == expected)
        }
        d.selectLive(from:point(10,10),to:point(10,11))
        #expect(d.pixelBounds(imageSize:imageSize) == nil)
    }

    @Test func tinyCornerHandlesStayInsideViewAndOutsideAutomaticBars() throws {
        _ = NSApplication.shared
        for origin in [CGPoint(x:0,y:0),CGPoint(x:398,y:0),CGPoint(x:0,y:318),CGPoint(x:398,y:318)] {
            let s = EditingSession(image:try EditingTests.fixture(),canvas:CGSize(width:400,height:320),fullScreen:false,writer:PreciseWriter())
            s.document.select(from:origin,to:CGPoint(x:origin.x+2,y:origin.y+2))
            let view = EditingCanvasView(session:s,selectingForTranslation:false)
            let window = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; window.contentView = view
            defer { window.contentView = nil; window.close() }
            view.layoutSubtreeIfNeeded()
            let x:CGFloat = origin.x == 0 ? 5 : 363, y:CGFloat = origin.y == 0 ? 5 : 283
            for p in [CGPoint(x:x,y:y),CGPoint(x:x+16,y:y),CGPoint(x:x+32,y:y),CGPoint(x:x+32,y:y+16),
                      CGPoint(x:x+32,y:y+32),CGPoint(x:x+16,y:y+32),CGPoint(x:x,y:y+32),CGPoint(x:x,y:y+16)] {
                #expect(view.bounds.insetBy(dx:4,dy:4).contains(p))
                #expect(!view.barFrames.toolbar.insetBy(dx:-4,dy:-4).contains(p))
                #expect(view.bounds.contains(view.selectionLabelFrame) && !view.selectionLabelFrame.insetBy(dx:-4,dy:-4).contains(p))
                #expect(view.cursor(at:p) != .arrow && view.cursor(at:p) != .openHand)
            }
            #expect(s.document.pixelBounds(imageSize:CGSize(width:200,height:160))?.size == CGSize(width:1,height:1))
        }
    }

    @Test func eachToolExportsAtOnePixelWithoutGrowingOrLosingUndo() throws {
        let source = try EditingTests.fixture()
        for tool in EditingTool.allCases {
            let s = EditingSession(image:source,canvas:CGSize(width:333.3,height:213.7),fullScreen:false,writer:PreciseWriter())
            s.document.select(from:CGPoint(x:20*333.3/200,y:30*213.7/160),to:CGPoint(x:21*333.3/200,y:31*213.7/160))
            let original = try s.composite()
            s.document.append(EditingMark(tool:tool,points:[.zero,CGPoint(x:0.2,y:0.2)],text:"1"))
            let output = try s.composite()
            #expect(output.width == 1 && output.height == 1 && s.document.marks.count == 1)
            #expect(s.blurredSourceImage()?.width == 1)
            s.document.undo(); #expect(try s.composite() == original)
            s.document.redo(); #expect(try s.composite() == output)
        }
    }

    @Test func allEightCornerHandlesPreserveZeroMotionAndMoveOneSourcePixel() throws {
        _ = NSApplication.shared
        for origin in [CGPoint(x:0,y:0),CGPoint(x:398,y:0),CGPoint(x:0,y:318),CGPoint(x:398,y:318)] {
            for handle in EditingDocument.Handle.allCases {
                let s = EditingSession(image:try EditingTests.fixture(),canvas:CGSize(width:400,height:320),fullScreen:false,writer:PreciseWriter())
                s.document.select(from:origin,to:CGPoint(x:origin.x+2,y:origin.y+2))
                let view = EditingCanvasView(session:s,selectingForTranslation:false)
                let window = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
                window.isReleasedWhenClosed = false; window.contentView = view
                defer { window.contentView = nil; window.close() }
                view.layoutSubtreeIfNeeded()
                let x:CGFloat = origin.x == 0 ? 5 : 363, y:CGFloat = origin.y == 0 ? 5 : 283
                let west = [.northWest,.west,.southWest].contains(handle)
                let east = [.northEast,.east,.southEast].contains(handle)
                let north = [.northWest,.north,.northEast].contains(handle)
                let south = [.southWest,.south,.southEast].contains(handle)
                let point = CGPoint(x:west ? x : east ? x+32 : x+16,y:north ? y : south ? y+32 : y+16)
                func mouse(_ type:NSEvent.EventType,_ p:CGPoint) -> NSEvent {
                    NSEvent.mouseEvent(with:type,location:view.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,
                        context:nil,eventNumber:0,clickCount:1,pressure:1)!
                }
                let original = try #require(s.document.pixelBounds(imageSize:CGSize(width:200,height:160)))
                view.mouseDown(with:mouse(.leftMouseDown,point))
                view.mouseDragged(with:mouse(.leftMouseDragged,point))
                #expect(s.document.pixelBounds(imageSize:CGSize(width:200,height:160)) == original)
                let delta = CGSize(width:west ? -2 : east ? 2 : 0,height:north ? -2 : south ? 2 : 0)
                let end = CGPoint(x:point.x+delta.width,y:point.y+delta.height)
                view.mouseDragged(with:mouse(.leftMouseDragged,end)); view.mouseUp(with:mouse(.leftMouseUp,end))
                let crop = try #require(s.document.pixelBounds(imageSize:CGSize(width:200,height:160)))
                #expect(crop.minX == original.minX-(west && original.minX > 0 ? 1 : 0))
                #expect(crop.maxX == original.maxX+(east && original.maxX < 200 ? 1 : 0))
                #expect(crop.minY == original.minY-(north && original.minY > 0 ? 1 : 0))
                #expect(crop.maxY == original.maxY+(south && original.maxY < 160 ? 1 : 0))
                let output = try s.composite(); #expect(output.width == Int(crop.width) && output.height == Int(crop.height))
            }
        }
    }

    @Test func thinSelectionsKeepLabelClearOfBothBars() async throws {
        _ = NSApplication.shared
        for rect in [CGRect(x:0,y:0,width:400,height:2),CGRect(x:0,y:318,width:400,height:2),
                     CGRect(x:0,y:0,width:2,height:320),CGRect(x:398,y:0,width:2,height:320)] {
            let s = EditingSession(image:try EditingTests.fixture(),canvas:CGSize(width:400,height:320),fullScreen:false,writer:PreciseWriter())
            s.document.select(from:rect.origin,to:CGPoint(x:rect.maxX,y:rect.maxY)); s.tool = .number
            let view = EditingCanvasView(session:s,selectingForTranslation:false)
            let window = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; window.contentView = view
            defer { window.contentView = nil; window.close() }
            await Task.yield(); view.needsLayout = true; view.layoutSubtreeIfNeeded()
            #expect(view.bounds.contains(view.selectionLabelFrame))
            #expect(!view.selectionLabelFrame.intersects(view.barFrames.toolbar))
            #expect(!view.selectionLabelFrame.intersects(view.barFrames.options))
        }
    }

    @Test func releaseCoordinatesCompleteCoalescedSelectionMoveAndResizeEvents() throws {
        _ = NSApplication.shared
        let s = EditingSession(image:try EditingTests.fixture(),canvas:CGSize(width:400,height:320),fullScreen:false,writer:PreciseWriter())
        let view = EditingCanvasView(session:s,selectingForTranslation:true)
        let window = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        var translated = 0; view.onTranslate = { translated += 1 }
        func mouse(_ type:NSEvent.EventType,_ p:CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:view.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,
                context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        let start = CGPoint(x:100,y:100), one = CGPoint(x:102,y:102), two = CGPoint(x:104,y:104)
        view.mouseDown(with:mouse(.leftMouseDown,start)); view.mouseUp(with:mouse(.leftMouseUp,one))
        #expect(translated == 1 && s.document.pixelBounds(imageSize:CGSize(width:200,height:160)) == CGRect(x:50,y:50,width:1,height:1))
        s.document.discardUnfinishedSelection()
        view.mouseDown(with:mouse(.leftMouseDown,start)); view.mouseMoved(with:mouse(.mouseMoved,one)); view.mouseUp(with:mouse(.leftMouseUp,one))
        #expect(translated == 2 && s.document.pixelBounds(imageSize:CGSize(width:200,height:160)) == CGRect(x:50,y:50,width:1,height:1))
        s.document.discardUnfinishedSelection()
        view.mouseDown(with:mouse(.leftMouseDown,start)); view.mouseDragged(with:mouse(.leftMouseDragged,one)); view.mouseUp(with:mouse(.leftMouseUp,two))
        #expect(translated == 3 && s.document.pixelBounds(imageSize:CGSize(width:200,height:160)) == CGRect(x:50,y:50,width:2,height:2))
        s.document.discardUnfinishedSelection()
        view.mouseDown(with:mouse(.leftMouseDown,start)); view.mouseDragged(with:mouse(.leftMouseDragged,one)); view.mouseUp(with:mouse(.leftMouseUp,start))
        #expect(translated == 3 && s.document.selection == nil)
        s.document.select(from:start,to:one)
        view.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:101,y:101))); view.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:103,y:101)))
        #expect(s.document.pixelBounds(imageSize:CGSize(width:200,height:160)) == CGRect(x:51,y:50,width:1,height:1))
        view.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:119,y:101))); view.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:121,y:101)))
        #expect(s.document.pixelBounds(imageSize:CGSize(width:200,height:160)) == CGRect(x:51,y:50,width:2,height:1))
        #expect(!window.isVisible)
    }

    @Test func pannedEdgeMoveHaloUsesUnclampedGestureDelta() throws {
        _ = NSApplication.shared
        let s = EditingSession(image:try EditingTests.fixture(),canvas:CGSize(width:400,height:320),fullScreen:false,writer:PreciseWriter())
        s.document.select(from:.zero,to:CGPoint(x:2,y:2))
        s.viewport.pan(by:CGSize(width:100,height:100),in:CGRect(x:0,y:0,width:400,height:320),canvas:s.document.canvas)
        #expect(s.viewport.offset == CGPoint(x:100,y:100))
        let view = EditingCanvasView(session:s,selectingForTranslation:false)
        let window = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        func mouse(_ type:NSEvent.EventType,_ p:CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:view.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,
                context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        let start = CGPoint(x:95,y:101), sourceSize = CGSize(width:200,height:160)
        #expect(view.cursor(at:start) == .openHand)
        view.mouseDown(with:mouse(.leftMouseDown,start))
        let version = s.document.renderVersion
        view.mouseDragged(with:mouse(.leftMouseDragged,start))
        #expect(s.document.pixelBounds(imageSize:sourceSize) == CGRect(x:0,y:0,width:1,height:1))
        #expect(s.document.renderVersion == version)
        view.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:95.5,y:101)))
        #expect(s.document.pixelBounds(imageSize:sourceSize) == CGRect(x:0,y:0,width:1,height:1))
        view.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:96,y:101)))
        #expect(s.document.pixelBounds(imageSize:sourceSize) == CGRect(x:1,y:0,width:1,height:1))
        view.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:97,y:101)))
        #expect(s.document.pixelBounds(imageSize:sourceSize) == CGRect(x:1,y:0,width:1,height:1))
        let output = try s.composite(); #expect(output.width == 1 && output.height == 1 && !window.isVisible)
    }

}
@MainActor private final class PreciseWriter: ImageOutputWriting {
    func copyImage(_ image:RasterImage) -> CopyOutcome { .failed }
}
