import AppKit
import Testing
import TrayletCore
@testable import TrayletApp

@MainActor struct ImportedImageTests {
    @Test func importsIntoCenteredNormalWindowWithOriginalAspectAndPixels() throws {
        _ = NSApplication.shared
        let image = try EditingTests.fixture()
        let decoded = try #require(EditingRenderer.decode(image))
        let writer = ImportedImageWriter()
        var capturedWindow: NSPanel?, capturedCanvas: EditingCanvasView?
        let controller = CaptureEditorController(writer:writer,presentPanel:{ capturedWindow = $0; capturedCanvas = $1 as? EditingCanvasView })
        defer { controller.cancel() }
        let frame = CGRect(x:-900,y:80,width:800,height:600)
        let opened = controller.presentImported(image:image,decoded:decoded,availableFrame:frame)
        #expect(opened)
        let window = try #require(capturedWindow), canvas = try #require(capturedCanvas)
        #expect(window.styleMask.contains(.titled) && window.styleMask.contains(.closable))
        #expect(!window.styleMask.contains(.resizable) && window.level == .normal)
        #expect(frame.contains(window.frame))
        #expect(abs(window.frame.midX - frame.midX) < 1 && abs(window.frame.midY - frame.midY) < 1)
        #expect(abs(canvas.bounds.width / canvas.bounds.height - 1.25) < 0.000001)
        #expect(canvas.session.document.selection == CGRect(origin:.zero,size:canvas.session.document.canvas))
        #expect(canvas.session.document.marks.isEmpty && !canvas.selectingForTranslation)
        #expect(canvas.session.sourceImage === decoded)
        let result = try canvas.session.composite()
        #expect(result.width == 200 && result.height == 160)
        let bitmap = try #require(NSBitmapImageRep(data:result.pngData))
        #expect(bitmap.colorAt(x:20,y:40)?.redComponent == 1)
        #expect(bitmap.colorAt(x:150,y:40)?.redComponent == 0)
        #expect(writer.calls == 0 && !window.isVisible)
    }

    @Test func busyCaptureAndImportedEditsRejectReplacementWithoutCompletingOrWriting() throws {
        _ = NSApplication.shared
        let image = try EditingTests.fixture(), decoded = try #require(EditingRenderer.decode(image))
        for startsAsCapture in [false,true] {
            let writer = ImportedImageWriter()
            var views: [EditingCanvasView] = [], windows: [NSPanel] = []
            let controller = CaptureEditorController(writer:writer,presentPanel:{ panel, view in windows.append(panel); views.append(view as! EditingCanvasView) })
            var completions = 0; controller.onComplete = { completions += 1 }
            let frame = CGRect(x:20,y:40,width:600,height:480)
            if startsAsCapture { controller.present(image:image,decoded:decoded,screenFrame:frame,initiallyFullScreen:true) }
            else { #expect(controller.presentImported(image:image,decoded:decoded,availableFrame:frame)) }
            let original = try #require(views.first)
            original.session.document.append(EditingMark(tool:.redaction,points:[CGPoint(x:10,y:10),CGPoint(x:40,y:40)]))
            let before = try original.session.composite()
            #expect(!controller.presentImported(image:image,decoded:decoded,availableFrame:frame))
            #expect(controller.isOpen && views.count == 1 && completions == 0 && writer.calls == 0)
            #expect(try original.session.composite() == before)
            controller.cancel()
            #expect(completions == 1 && !controller.isOpen && !windows[0].isVisible)
        }
    }

    @Test func invalidDimensionsAndInsufficientFrameDoNotPresentOrWrite() throws {
        _ = NSApplication.shared
        let image = try EditingTests.fixture(), decoded = try #require(EditingRenderer.decode(image))
        let mismatch = try #require(decoded.cropping(to:CGRect(x:0,y:0,width:100,height:100)))
        let writer = ImportedImageWriter()
        var presentations = 0, completions = 0
        let controller = CaptureEditorController(writer:writer,presentPanel:{ _, _ in presentations += 1 })
        controller.onComplete = { completions += 1 }
        #expect(!controller.presentImported(image:image,decoded:mismatch,availableFrame:CGRect(x:0,y:0,width:800,height:600)))
        for frame in [CGRect.zero,CGRect(x:0,y:0,width:179,height:300),CGRect(x:0,y:0,width:300,height:159),CGRect(x:CGFloat.nan,y:0,width:800,height:600)] {
            #expect(!controller.presentImported(image:image,decoded:decoded,availableFrame:frame))
        }
        #expect(!controller.isOpen && presentations == 0 && completions == 0 && writer.calls == 0)
    }

    @Test func hiddenCaptureIsReleasedBeforeAnotherCaptureAndCompletesOnce() throws {
        _ = NSApplication.shared
        let image = try EditingTests.fixture()
        var views: [EditingCanvasView] = [], windows: [NSPanel] = []
        let controller = CaptureEditorController(writer:ImportedImageWriter(),
            presentPanel:{ panel, view in windows.append(panel); views.append(view as! EditingCanvasView) })
        var completions = 0; controller.onComplete = { completions += 1 }
        let frame = CGRect(x:0,y:0,width:800,height:600)
        controller.present(image:image,screenFrame:frame,initiallyFullScreen:true)
        #expect(controller.isOpen && views.count == 1 && !windows[0].hidesOnDeactivate)

        // The injected presenter never orders the panel on screen, which reproduces the
        // stale state left behind when AppKit hides an otherwise unclosed capture panel.
        controller.discardHiddenSession()
        #expect(!controller.isOpen && completions == 1)

        controller.present(image:image,screenFrame:frame,initiallyFullScreen:true)
        #expect(controller.isOpen && views.count == 2 && completions == 1)
        controller.cancel()
        #expect(!controller.isOpen && completions == 2)
    }

    @Test func closeEscapeAndCopyCompleteOnceAndRetiredCallbacksCannotCloseReplacement() throws {
        _ = NSApplication.shared
        let image = try EditingTests.fixture(), decoded = try #require(EditingRenderer.decode(image))
        let writer = ImportedImageWriter()
        var views: [EditingCanvasView] = [], windows: [NSPanel] = []
        let controller = CaptureEditorController(writer:writer,presentPanel:{ panel, view in windows.append(panel); views.append(view as! EditingCanvasView) })
        var completions = 0; controller.onComplete = { completions += 1 }
        let frame = CGRect(x:0,y:0,width:800,height:600)
        for action in 0..<3 {
            #expect(controller.presentImported(image:image,decoded:decoded,availableFrame:frame))
            let canvas = views.last!, window = windows.last!
            if action == 0 { window.performClose(nil) }
            if action == 1 { canvas.keyDown(with:key("",code:53,window:window)) }
            if action == 2 {
                writer.outcome = .failed
                canvas.keyDown(with:key("c",code:8,flags:.command,window:window))
                #expect(controller.isOpen && completions == 2)
                writer.outcome = .copied
                canvas.keyDown(with:key("c",code:8,flags:.command,window:window))
            }
            controller.cancel(); canvas.onCancel?(); window.close()
            #expect(!controller.isOpen && completions == action + 1 && !window.isVisible)
        }
        #expect(writer.calls == 2)
        #expect(controller.presentImported(image:image,decoded:decoded,availableFrame:frame))
        views[0].onCancel?(); views[0].onSave?(); windows[0].close()
        #expect(controller.isOpen && completions == 3)
        controller.cancel(); #expect(completions == 4)
    }

    @Test func saveCancellationFailureSuccessAndLateCompletionUseExistingLifecycle() throws {
        _ = NSApplication.shared
        let image = try EditingTests.fixture(), decoded = try #require(EditingRenderer.decode(image))
        let writer = ImportedImageWriter()
        var pending: ((URL?) -> Void)?, view: EditingCanvasView?
        let controller = CaptureEditorController(writer:writer,chooseSaveDestination:{ _, complete in pending = complete },presentPanel:{ _, canvas in view = canvas as? EditingCanvasView })
        var completions = 0; controller.onComplete = { completions += 1 }
        let frame = CGRect(x:0,y:0,width:600,height:400)
        #expect(controller.presentImported(image:image,decoded:decoded,availableFrame:frame))
        view?.onSave?(); pending?(nil)
        #expect(controller.isOpen && completions == 0)
        view?.onSave?(); pending?(URL(fileURLWithPath:"/dev/null/no-image.png"))
        #expect(controller.isOpen && completions == 0)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-imported-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at:target) }
        view?.onSave?(); pending?(target)
        #expect(!controller.isOpen && completions == 1)
        let saved = try RasterImage(pngData:Data(contentsOf:target))
        #expect(saved.width == 200 && saved.height == 160 && writer.calls == 0)
        #expect(controller.presentImported(image:image,decoded:decoded,availableFrame:frame))
        view?.onSave?(); let retired = pending; controller.cancel()
        #expect(controller.presentImported(image:image,decoded:decoded,availableFrame:frame))
        retired?(target)
        #expect(controller.isOpen && completions == 2)
        controller.cancel(); #expect(completions == 3)
    }

    @Test func extremeAspectImagesStayWholeAndToolbarDragUsesVisibleWindowBounds() throws {
        _ = NSApplication.shared
        for size in [CGSize(width:4000,height:40),CGSize(width:40,height:4000),CGSize(width:2,height:1)] {
            let context = try #require(CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(origin:.zero,size:size))
            let decoded = try #require(context.makeImage()), image = try EditingRenderer.encode(decoded)
            let sourceBitmap = try #require(NSBitmapImageRep(data:image.pngData))
            let sourceColor = try #require(sourceBitmap.colorAt(x:0,y:0)?.usingColorSpace(.deviceRGB))
            for frame in [CGRect(x:-500,y:100,width:240,height:240),CGRect(x:100,y:20,width:1600,height:1000)] {
                var capturedWindow: NSPanel?, capturedCanvas: EditingCanvasView?
                let controller = CaptureEditorController(writer:ImportedImageWriter(),presentPanel:{ capturedWindow = $0; capturedCanvas = $1 as? EditingCanvasView })
                defer { controller.cancel() }
                #expect(controller.presentImported(image:image,decoded:decoded,availableFrame:frame))
                let window = try #require(capturedWindow), canvas = try #require(capturedCanvas)
                canvas.layoutSubtreeIfNeeded()
                #expect(frame.contains(window.frame))
                #expect(canvas.bounds.width >= 180 && canvas.bounds.height >= 160)
                let selection = try #require(canvas.session.document.selection)
                let displayed = canvas.session.viewport.viewRect(selection)
                #expect(canvas.bounds.insetBy(dx:-0.001,dy:-0.001).contains(displayed))
                #expect(abs(selection.width / selection.height - size.width / size.height) < 0.00001)
                let toolbar = try #require(canvas.subviews.first as? EditingBarHost<EditingToolbar>)
                #expect(toolbar.intrinsicContentSize.width <= toolbar.frame.width + 1)
                let old = toolbar.frame
                toolbar.rootView.drag(CGSize(width:20,height:20),true)
                let expected = CGPoint(x:max(4,min(canvas.bounds.width-old.width-4,old.minX+20)),y:max(4,min(canvas.bounds.height-old.height-4,old.minY+20)))
                #expect(toolbar.frame.origin == expected)
                canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded()
                #expect(toolbar.frame.origin == expected)
                let output = try canvas.session.composite()
                #expect(output.width == Int(size.width) && output.height == Int(size.height))
                let bitmap = try #require(NSBitmapImageRep(data:output.pngData))
                let color = try #require(bitmap.colorAt(x:0,y:0)?.usingColorSpace(.deviceRGB))
                #expect(color.redComponent == sourceColor.redComponent && color.greenComponent == sourceColor.greenComponent && color.blueComponent == sourceColor.blueComponent && color.alphaComponent == sourceColor.alphaComponent)
                #expect(!window.isVisible)
            }
        }
    }

    @Test(.enabled(if:ProcessInfo.processInfo.environment["TRAYLET_IMPORTED_IMAGE_EVIDENCE_DIR"] != nil))
    func hiddenImportedNativeWindowGallery() async throws {
        _ = NSApplication.shared
        let directoryPath = try #require(ProcessInfo.processInfo.environment["TRAYLET_IMPORTED_IMAGE_EVIDENCE_DIR"])
        #expect(directoryPath.hasPrefix("/"))
        guard directoryPath.hasPrefix("/") else { return }
        let directory = URL(fileURLWithPath:directoryPath,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let previousLanguage = V2Localization.shared.languageCode
        let previousGlass = V2AppearanceState.shared.glassEnabled
        V2AppearanceState.shared.glassEnabled = false
        defer { V2Localization.shared.languageCode = previousLanguage; V2AppearanceState.shared.glassEnabled = previousGlass }
        for (name,size,available) in [("normal",CGSize(width:800,height:500),CGSize(width:680,height:580)),
                                     ("wide",CGSize(width:4000,height:40),CGSize(width:240,height:240)),
                                     ("tall",CGSize(width:40,height:4000),CGSize(width:240,height:360))] {
            let source: RasterImage
            if name == "normal" { source = try EditingTests.showcaseImage() }
            else {
                let context = try #require(CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,
                    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(CGColor(red:0.15,green:0.45,blue:0.9,alpha:1)); context.fill(CGRect(origin:.zero,size:size))
                source = try EditingRenderer.encode(#require(context.makeImage()))
            }
            let decoded = try #require(EditingRenderer.decode(source))
            for (appearanceName,appearance,language) in [("light",NSAppearance.Name.aqua,"zh-Hans"),("dark",NSAppearance.Name.darkAqua,"en")] {
                V2Localization.shared.languageCode = language
                var capturedWindow: NSPanel?, capturedCanvas: EditingCanvasView?
                let writer = ImportedImageWriter()
                let controller = CaptureEditorController(writer:writer,presentPanel:{ capturedWindow = $0; capturedCanvas = $1 as? EditingCanvasView })
                defer { controller.cancel() }
                #expect(controller.presentImported(image:source,decoded:decoded,availableFrame:CGRect(origin:CGPoint(x:20,y:40),size:available)))
                let window = try #require(capturedWindow), canvas = try #require(capturedCanvas)
                window.appearance = NSAppearance(named:appearance)
                await Task.yield()
                canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded()
                let toolbar = try #require(canvas.subviews.first)
                #expect(canvas.bounds.contains(toolbar.frame) && toolbar.frame.height == 36)
                #expect(toolbar.intrinsicContentSize.width <= toolbar.frame.width + 1)
                let nativeFrame = window.contentView?.superview ?? canvas
                nativeFrame.layoutSubtreeIfNeeded()
                let bitmap = try #require(nativeFrame.bitmapImageRepForCachingDisplay(in:nativeFrame.bounds))
                nativeFrame.cacheDisplay(in:nativeFrame.bounds,to:bitmap)
                try #require(bitmap.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent("imported-\(name)-\(appearanceName).png"))
                #expect(!window.isVisible && writer.calls == 0)
            }
        }
    }

    private func key(_ text:String,code:UInt16,flags:NSEvent.ModifierFlags = [],window:NSWindow) -> NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,
            characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!
    }
}

@MainActor private final class ImportedImageWriter: ImageOutputWriting {
    var calls = 0
    var outcome: CopyOutcome = .copied
    func copyImage(_ image:RasterImage) -> CopyOutcome { calls += 1; return outcome }
}
