import AppKit
import Testing
import TrayletCore
@testable import TrayletApp

@MainActor struct TextObjectEvidenceTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["TRAYLET_TEXT_OBJECT_EVIDENCE_DIR"] != nil))
    func hiddenTextSelectionDraftAndExportGallery() async throws {
        _ = NSApplication.shared
        let path = try #require(ProcessInfo.processInfo.environment["TRAYLET_TEXT_OBJECT_EVIDENCE_DIR"])
        #expect(path.hasPrefix("/")); guard path.hasPrefix("/") else { return }
        let directory = URL(fileURLWithPath:path,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let appearance = NSApp.appearance, language = V2Localization.shared.languageCode, glass = V2AppearanceState.shared.glassEnabled
        defer { NSApp.appearance = appearance; V2Localization.shared.languageCode = language; V2AppearanceState.shared.glassEnabled = glass }
        V2AppearanceState.shared.glassEnabled = false
        let context = try #require(CGContext(data:nil,width:1800,height:1200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x:0,y:0,width:1800,height:1200))
        let source = try EditingRenderer.encode(#require(context.makeImage()))
        var measurements:[[String:Any]] = []
        for narrow in [false,true] {
            NSApp.appearance = NSAppearance(named:narrow ? .darkAqua : .aqua)
            V2Localization.shared.languageCode = narrow ? "en" : "zh-Hans"
            let size = narrow ? CGSize(width:180,height:320) : CGSize(width:900,height:600)
            let s = EditingSession(image:source,canvas:size,fullScreen:true,writer:TextEvidenceWriter())
            s.tool = .text; s.style.fontSize = 18
            if !narrow { s.document.select(from:CGPoint(x:40,y:30),to:CGPoint(x:860,y:510)) }
            let text = narrow ? "Edit text\n再次编辑" : "再次编辑 · Text object\n原文保留，支持换行"
            s.document.append(EditingMark(tool:.text,points:[CGPoint(x:24,y:50)],style:EditingStyle(color:.systemBlue,fontSize:narrow ? 20 : 28),text:text,textWidth:narrow ? 140 : 600))
            let id = try #require(s.document.selectedMarkID)
            if !narrow { s.document.append(EditingMark(tool:.redaction,points:[CGPoint(x:330,y:75),CGPoint(x:470,y:108)])) }
            let view = EditingCanvasView(session:s,selectingForTranslation:false)
            let window = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.appearance = NSApp.appearance
            defer { window.contentView = nil; window.close() }
            s.selectObject(id)
            func capture(_ name:String) async throws {
                await Task.yield(); view.needsLayout = true; view.layoutSubtreeIfNeeded(); view.needsDisplay = true
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in:view.bounds)); view.cacheDisplay(in:view.bounds,to:bitmap)
                let opaque = try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:bitmap.pixelsWide,pixelsHigh:bitmap.pixelsHigh,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:opaque)
                let rect = CGRect(x:0,y:0,width:opaque.pixelsWide,height:opaque.pixelsHigh)
                window.effectiveAppearance.performAsCurrentDrawingAppearance { NSColor.windowBackgroundColor.setFill(); rect.fill(); bitmap.draw(in:rect) }
                NSGraphicsContext.restoreGraphicsState()
                try #require(opaque.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent(name+".png"))
                #expect(!window.isVisible && view.bounds.contains(view.barFrames.options))
                measurements.append(["name":name,"canvasWidth":size.width,"optionsWidth":view.barFrames.options.width,"selectedFontSize":s.effectiveStyle.fontSize,"defaultFontSize":s.style.fontSize,"isEditingText":s.isEditingText])
            }
            try await capture(narrow ? "text-dark-180-selected" : "text-light-selected")
            let event = try #require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36))
            window.makeFirstResponder(view); view.keyDown(with:event)
            let editor = try #require(window.firstResponder as? NSTextView)
            editor.string = narrow ? "Draft 草稿\nReturn ↵" : "正在编辑 · Active draft\nCommand-Return 提交，Esc 取消"
            editor.setSelectedRange(NSRange(location:0,length:0))
            try await capture(narrow ? "text-dark-180-draft" : "text-light-draft")
            #expect(view.finishText())
            var changed = s.effectiveStyle; changed.fontSize = narrow ? 24 : 36; changed.color = .systemRed
            #expect(s.setEffectiveStyle(changed,context:s.captureStyleContext()))
            let pending = s.document.beginObjectEdit(.move), token = try #require(pending)
            _ = s.document.moveObject(token,totalCanvasDelta:CGSize(width:8,height:12)); _ = s.document.commitObjectEdit(token)
            if !narrow {
                try await capture("text-light-after")
                let export = try s.composite(); s.selectObject(nil); #expect(try s.composite() == export)
                #expect(export.width == 1640 && export.height == 960)
                try export.pngData.write(to:directory.appendingPathComponent("text-export.png"))
            }
        }
        try JSONSerialization.data(withJSONObject:measurements,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("text-layout.json"))
    }
}
@MainActor private final class TextEvidenceWriter: ImageOutputWriting {
    func copyImage(_ image:RasterImage) -> CopyOutcome { .failed }
}
