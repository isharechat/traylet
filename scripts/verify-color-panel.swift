import AppKit
import SwiftUI
import TrayletCore

/// Compiled with application sources, excluding V2TrayletMain. Uses only synthetic pixels.
@main enum ColorPanelVerification {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
            Task { @MainActor in
                do { try await verify(); print("COLOR_PANEL_INTERACTION_PASS"); exit(0) }
                catch { print("COLOR_PANEL_INTERACTION_FAIL: \(error)"); exit(1) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+20) { print("COLOR_PANEL_INTERACTION_TIMEOUT"); exit(2) }
        app.run()
    }
    enum Failure: Error { case check(String) }
    @MainActor static func check(_ condition:Bool,_ message:String) throws {
        guard condition else { throw Failure.check(message) }
        print("PASS \(message)"); fflush(stdout)
    }
    @MainActor static func descendants(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func verify() async throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:900,pixelsHigh:600,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        for y in 0..<600 { for x in 0..<900 { bitmap.setColor(NSColor(deviceRed:1,green:1,blue:1,alpha:1),atX:x,y:y) } }
        let image = try RasterImage(pngData:bitmap.representation(using:.png,properties:[:])!)
        let panel = NSColorPanel.shared
        panel.orderOut(nil)
        let level = panel.level
        var canvas: EditingCanvasView!
        var window: NSPanel!
        let controller = CaptureEditorController(presentPanel:{ w,v in
            window = w; canvas = v as? EditingCanvasView
            w.makeKeyAndOrderFront(nil); w.makeFirstResponder(v); NSApp.activate(ignoringOtherApps:true)
        })
        defer { controller.cancel() }
        let screen = NSScreen.main!.visibleFrame
        controller.present(image:image,screenFrame:CGRect(x:screen.minX+40,y:screen.minY+40,width:900,height:600),initiallyFullScreen:true)
        canvas.session.tool = .rectangle
        try await Task.sleep(for:.milliseconds(400))
        canvas.layoutSubtreeIfNeeded()
        guard let well = descendants(canvas).compactMap({ $0 as? EditingNativeColorWell }).first else { throw Failure.check("Missing native color well") }
        try check(canvas.session.style.color.isEqual(NSColor.systemRed), "new screenshot annotation defaults to red")
        try check(!descendants(canvas).contains(where: { $0 is EditingPaletteButton }), "quick colors do not occupy annotation toolbar")
        print("canvas=\(canvas.frame) options=\(canvas.barFrames.options) well=\(well.frame) hidden=\(well.isHiddenOrHasHiddenAncestor)")
        func click() throws {
            let p = well.convert(NSPoint(x:well.bounds.midX,y:well.bounds.midY),to:nil)
            let now = ProcessInfo.processInfo.systemUptime
            let up = NSEvent.mouseEvent(with:.leftMouseUp,location:p,modifierFlags:[],timestamp:now+0.01,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0)!
            NSApp.postEvent(up,atStart:true)
            NSApp.sendEvent(NSEvent.mouseEvent(with:.leftMouseDown,location:p,modifierFlags:[],timestamp:now,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!)
        }
        try click()
        try await Task.sleep(for:.milliseconds(250))
        try check(well.isActive && panel.isVisible && panel.isKeyWindow,"mouse click opens a key color panel")
        try check(panel.level.rawValue == window.level.rawValue+1,"picker is above screenshot: \(panel.level.rawValue) > \(window.level.rawValue)")
        guard let accessory = panel.accessoryView as? EditingColorPaletteView else { throw Failure.check("Missing picker quick colors") }
        let quickColors = descendants(accessory).compactMap { $0 as? EditingPaletteButton }
        try check(quickColors.count == 8, "all eight quick colors are inside the picker")
        guard let blue = quickColors.first(where: { $0.paletteColor.isEqual(NSColor.systemBlue) }) else { throw Failure.check("Missing blue shortcut") }
        blue.performClick(nil)
        try await Task.sleep(for: .milliseconds(100))
        try check(canvas.session.style.color.isEqual(NSColor.systemBlue), "picker quick color reaches editing session")
        panel.color = NSColor(srgbRed:0,green:0,blue:1,alpha:1)
        try await Task.sleep(for:.milliseconds(150))
        let color = canvas.session.style.color.usingColorSpace(.deviceRGB)!
        try check(color.blueComponent > 0.98 && color.greenComponent < 0.02 && color.redComponent < 0.02,"system panel color reaches editing session")
        canvas.session.style.filled = true
        func event(_ type:NSEvent.EventType,_ point:CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        canvas.mouseDown(with:event(.leftMouseDown,CGPoint(x:100,y:100)))
        canvas.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:400,y:400)))
        canvas.mouseUp(with:event(.leftMouseUp,CGPoint(x:400,y:400)))
        let output = try canvas.session.composite()
        let pixel = NSBitmapImageRep(data:output.pngData)!.colorAt(x:200,y:200)!.usingColorSpace(.deviceRGB)!
        print("export pixel=\(pixel), marks=\(canvas.session.document.marks.count)")
        // Compare in the renderer's output space; display/device RGB numbers are not sRGB components.
        var reference = EditingDocument(canvas:CGSize(width:900,height:600),fullScreen:true)
        reference.append(EditingMark(tool:.rectangle,points:[CGPoint(x:100,y:100),CGPoint(x:400,y:400)],style:EditingStyle(color:NSColor(srgbRed:0,green:0,blue:1,alpha:1),filled:true)))
        let expectedImage = try EditingRenderer.render(image,document:reference)
        let expected = NSBitmapImageRep(data:expectedImage.pngData)!.colorAt(x:200,y:200)!.usingColorSpace(.deviceRGB)!
        try check(abs(pixel.blueComponent-expected.blueComponent)<0.005 && abs(pixel.greenComponent-expected.greenComponent)<0.005 && abs(pixel.redComponent-expected.redComponent)<0.005 && pixel.blueComponent-pixel.greenComponent > 0.5,"drawn rectangle export matches reference blue in the same color space")
        let url = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        for (name,view) in [("editor",canvas as NSView),("color-panel",panel.contentView!)] {
            view.displayIfNeeded()
            let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:rep)
            try rep.representation(using:.png,properties:[:])!.write(to:url.appendingPathComponent(name+".png"))
        }
        try output.pngData.write(to:url.appendingPathComponent("selected-color-export.png"))
        panel.close()
        try await Task.sleep(for:.milliseconds(100))
        try click()
        try await Task.sleep(for:.milliseconds(150))
        try check(well.isActive && panel.isVisible && panel.level.rawValue > window.level.rawValue,"close and click again reopens picker")
        canvas.session.tool = .blur
        try await Task.sleep(for:.milliseconds(150))
        try check(!panel.isVisible && panel.level == level,"switch to blur closes picker and restores level")
        canvas.session.tool = .rectangle
        try await Task.sleep(for:.milliseconds(150))
        let next = descendants(canvas).compactMap { $0 as? EditingNativeColorWell }.first!
        next.activate(true)
        controller.cancel()
        try check(!panel.isVisible && panel.level == level && !controller.isOpen,"capture cancellation closes picker and restores state")
        try await verifyManualLimits()
    }

    @MainActor static func verifyManualLimits() async throws {
        var value = 100
        var commits: [Int] = []
        let binding = Binding<Int>(get: { value }, set: { value = $0; commits.append($0) })
        let host = NSHostingView(rootView: ClipboardLimitField("最大数量", unit: "条", value: binding, range: 1...1000)
            .padding(16).frame(width: 260, height: 100))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(150))
        guard let field = descendants(host).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) else { throw Failure.check("Missing editable clipboard limit") }
        func enter(_ text: String) throws -> NSTextView {
            window.makeFirstResponder(field)
            guard let editor = window.fieldEditor(true, for: field) as? NSTextView else { throw Failure.check("Missing clipboard field editor") }
            editor.selectAll(nil); editor.insertText(text, replacementRange: editor.selectedRange())
            return editor
        }
        let editor = try enter("37")
        try await Task.sleep(for: .milliseconds(100))
        try check(value == 100 && commits.isEmpty, "typing a clipboard limit does not commit a partial value")
        editor.insertNewline(nil); try await Task.sleep(for: .milliseconds(100))
        try check(value == 37 && commits == [37], "Return commits a manually entered clipboard limit once")
        let invalid = try enter("0")
        invalid.insertNewline(nil); try await Task.sleep(for: .milliseconds(100))
        try check(value == 37 && commits == [37], "invalid clipboard limit leaves saved value unchanged")
        _ = try enter("70")
        try await Task.sleep(for: .milliseconds(80))
        window.makeFirstResponder(nil); try await Task.sleep(for: .milliseconds(100))
        try check(value == 70 && commits == [37, 70], "leaving clipboard input commits the complete value")
    }
}
