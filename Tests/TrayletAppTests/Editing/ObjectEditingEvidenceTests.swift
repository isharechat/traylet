import AppKit
import Testing
import TrayletCore
@testable import TrayletApp

@MainActor struct ObjectEditingEvidenceTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["TRAYLET_OBJECT_EDITING_EVIDENCE_DIR"] != nil))
    func hiddenSelectedObjectBeforeAfterAndNarrowGallery() async throws {
        _ = NSApplication.shared
        let path = try #require(ProcessInfo.processInfo.environment["TRAYLET_OBJECT_EDITING_EVIDENCE_DIR"])
        #expect(path.hasPrefix("/")); guard path.hasPrefix("/") else { return }
        let directory = URL(fileURLWithPath:path,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let appearance = NSApp.appearance
        let language = V2Localization.shared.languageCode, glass = V2AppearanceState.shared.glassEnabled
        V2AppearanceState.shared.glassEnabled = false
        defer { NSApp.appearance = appearance; V2Localization.shared.languageCode = language; V2AppearanceState.shared.glassEnabled = glass }
        var report:[[String:Any]] = []
        for tool in [EditingTool.number,.arrow] {
            for narrow in [false,true] {
                V2Localization.shared.languageCode = narrow ? "en" : "zh-Hans"
                NSApp.appearance = NSAppearance(named:narrow ? .darkAqua : .aqua)
                let source = narrow ? try EditingTests.fixture() : try EditingTests.showcaseImage()
                let size = narrow ? CGSize(width:180,height:320) : CGSize(width:900,height:900*1440/2200.0)
                let s = EditingSession(image:source,canvas:size,fullScreen:true,writer:ObjectEvidenceWriter())
                if !narrow { s.document.select(from:CGPoint(x:80,y:50),to:CGPoint(x:820,y:480)) }
                s.tool = tool; s.style = EditingStyle(color:.systemGreen,width:2,fontSize:18)
                let points = narrow ? (tool == .number ? [CGPoint(x:65,y:95)] : [CGPoint(x:25,y:100),CGPoint(x:120,y:145)])
                    : (tool == .number ? [CGPoint(x:200,y:140)] : [CGPoint(x:140,y:180),CGPoint(x:350,y:100)])
                s.document.append(EditingMark(tool:tool,points:points,style:EditingStyle(color:.systemRed,width:4,fontSize:24)))
                let id = try #require(s.document.marks.last?.id)
                if !narrow { s.viewport.fit(s.document.selection!,in:CGRect(x:24,y:24,width:852,height:440),canvas:size) }
                let view = EditingCanvasView(session:s,selectingForTranslation:false)
                let window = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
                window.isReleasedWhenClosed = false; window.contentView = view
                window.appearance = NSAppearance(named:narrow ? .darkAqua : .aqua)
                defer { window.contentView = nil; window.close() }
                s.selectObject(id)
                func capture(_ name:String) async throws {
                    await Task.yield(); view.needsLayout = true; view.layoutSubtreeIfNeeded(); view.needsDisplay = true
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in:view.bounds)); view.cacheDisplay(in:view.bounds,to:bitmap)
                    let opaque = try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:bitmap.pixelsWide,pixelsHigh:bitmap.pixelsHigh,
                        bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:opaque)
                    let rect = CGRect(x:0,y:0,width:opaque.pixelsWide,height:opaque.pixelsHigh)
                    window.effectiveAppearance.performAsCurrentDrawingAppearance { NSColor.windowBackgroundColor.setFill(); rect.fill(); bitmap.draw(in:rect) }
                    NSGraphicsContext.restoreGraphicsState()
                    try #require(opaque.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent(name+".png"))
                    let options = try #require(view.subviews.dropFirst().first)
                    #expect(options.intrinsicContentSize.width <= options.frame.width+1 && view.bounds.contains(options.frame))
                    #expect(!window.isVisible)
                    report.append(["name":name,"canvasWidth":size.width,"canvasHeight":size.height,"zoom":s.viewport.scale,
                        "selectedFontSize":s.effectiveStyle.fontSize,"selectedLineWidth":s.effectiveStyle.width,
                        "defaultFontSize":s.style.fontSize,"defaultLineWidth":s.style.width,
                        "optionsWidth":options.intrinsicContentSize.width])
                }
                if !narrow { try await capture(tool.rawValue+"-light-before") }
                var changed = s.effectiveStyle; changed.color = .systemBlue; changed.width = 10; changed.fontSize = 36
                #expect(s.setEffectiveStyle(changed,context:s.captureStyleContext()))
                let pending = s.document.beginObjectEdit(.move), token = try #require(pending)
                _ = s.document.moveObject(token,totalCanvasDelta:CGSize(width:8*size.width/CGFloat(source.width),height:4*size.height/CGFloat(source.height)))
                _ = s.document.commitObjectEdit(token)
                try await capture(tool.rawValue+(narrow ? "-dark-180-after" : "-light-after"))
                let output = try s.composite(), pixels = try #require(s.document.pixelBounds(imageSize:CGSize(width:source.width,height:source.height)))
                #expect(output.width == Int(pixels.width) && output.height == Int(pixels.height))
                s.selectObject(nil); #expect(try s.composite() == output)
                if !narrow { try output.pngData.write(to:directory.appendingPathComponent(tool.rawValue+"-export.png")) }
            }
        }
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("object-style-layout.json"))
    }
}
@MainActor private final class ObjectEvidenceWriter: ImageOutputWriting {
    func copyImage(_ image:RasterImage) -> CopyOutcome { .failed }
}
