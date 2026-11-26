import AppKit
import Testing
import TrayletCore
@testable import TrayletApp

@MainActor struct EditingFocusLossTests {
    @Test func unfinishedSelectionIsDiscardedOnEitherFocusLossAndLateReleaseCannotSubmit() throws {
        for translation in [false, true] {
            for distance in [CGFloat(5), 80] {
                for notification in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
                    let fixture = try FocusFixture(translation:translation)
                    defer { fixture.close() }
                    let session = fixture.session, canvas = fixture.canvas
                    session.viewport.pan(by:CGSize(width:12,height:8),in:canvas.bounds,canvas:session.document.canvas)
                    let viewport = session.viewport
                    var submissions = 0; canvas.onTranslate = { submissions += 1 }
                    let start = viewport.viewPoint(CGPoint(x:100,y:100))
                    let end = viewport.viewPoint(CGPoint(x:100+distance,y:100+distance))
                    canvas.mouseDown(with:fixture.mouse(.leftMouseDown,start))
                    canvas.mouseDragged(with:fixture.mouse(.leftMouseDragged,end))
                    #expect(session.document.selection != nil)
                    fixture.loseFocus(notification)
                    canvas.layoutSubtreeIfNeeded()
                    #expect(session.document.selection == nil, "Discard unfinished \(distance)pt selection on \(notification.rawValue)")
                    let barsHidden = canvas.subviews.allSatisfy { $0.isHidden }
                    #expect(barsHidden)
                    #expect(session.viewport == viewport && session.document.marks.isEmpty)
                    canvas.mouseDragged(with:fixture.mouse(.leftMouseDragged,viewport.viewPoint(CGPoint(x:300,y:300))))
                    canvas.mouseUp(with:fixture.mouse(.leftMouseUp,end))
                    canvas.mouseUp(with:fixture.mouse(.leftMouseUp,end))
                    #expect(session.document.selection == nil && submissions == 0)
                    // A fresh gesture remains usable and translates only after its own explicit release.
                    canvas.mouseDown(with:fixture.mouse(.leftMouseDown,start))
                    let next = viewport.viewPoint(CGPoint(x:250,y:220))
                    canvas.mouseDragged(with:fixture.mouse(.leftMouseDragged,next))
                    canvas.mouseUp(with:fixture.mouse(.leftMouseUp,next))
                    #expect(session.document.selection == CGRect(x:99,y:99,width:153,height:123))
                    #expect(submissions == (translation ? 1 : 0))
                    #expect(!fixture.window.isVisible)
                }
            }
        }
    }

    @Test func focusLossDiscardsOnlyPreviewAndPreservesCompletedSelectionMarksViewportAndOutput() throws {
        for notification in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            let fixture = try FocusFixture(translation:false)
            defer { fixture.close() }
            let session = fixture.session, canvas = fixture.canvas
            session.document.select(from:CGPoint(x:100,y:100),to:CGPoint(x:300,y:250))
            session.document.append(EditingMark(tool:.rectangle,points:[CGPoint(x:10,y:10),CGPoint(x:60,y:50)]))
            session.viewport.fit(session.document.selection!,in:CGRect(x:24,y:24,width:552,height:352),canvas:session.document.canvas)
            session.viewport.pan(by:CGSize(width:12,height:8),in:canvas.bounds,canvas:session.document.canvas)
            let viewport = session.viewport, selection = session.document.selection, version = session.document.renderVersion
            let marks = session.document.marks
            let output = try session.composite()
            session.tool = .redaction
            let start = viewport.viewPoint(CGPoint(x:150,y:150)), end = viewport.viewPoint(CGPoint(x:180,y:180))
            canvas.mouseDown(with:fixture.mouse(.leftMouseDown,start))
            canvas.mouseDragged(with:fixture.mouse(.leftMouseDragged,end))
            fixture.loseFocus(notification)
            canvas.mouseUp(with:fixture.mouse(.leftMouseUp,end))
            #expect(session.document.selection == selection && session.document.renderVersion == version)
            #expect(session.document.marks.count == marks.count && session.document.marks.first?.points == marks.first?.points)
            #expect(session.viewport == viewport)
            #expect(try session.composite() == output)
            #expect(!fixture.window.isVisible)
        }
    }
}

@MainActor private final class FocusFixture {
    let session: EditingSession
    let canvas: EditingCanvasView
    let window: NSWindow
    init(translation:Bool) throws {
        _ = NSApplication.shared
        session = EditingSession(image:try EditingTests.fixture(),canvas:CGSize(width:600,height:480),fullScreen:false,writer:FocusWriter())
        canvas = EditingCanvasView(session:session,selectingForTranslation:translation)
        window = NSWindow(contentRect:canvas.bounds,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = canvas; window.makeFirstResponder(canvas)
    }
    func close() { window.contentView = nil; window.close() }
    func loseFocus(_ name:Notification.Name) {
        NotificationCenter.default.post(name:name,object:name == NSWindow.didResignKeyNotification ? window : NSApp)
    }
    func mouse(_ type:NSEvent.EventType,_ point:CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:0,
            windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
    }
}

@MainActor private final class FocusWriter: ImageOutputWriting {
    func copyImage(_ image:RasterImage) -> CopyOutcome { .failed }
}
