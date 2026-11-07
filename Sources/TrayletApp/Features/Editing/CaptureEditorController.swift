import AppKit
import TrayletCore
import UniformTypeIdentifiers

@MainActor final class CaptureEditorController: NSObject, NSWindowDelegate {
    private var panel: EditingPanel?
    private var canvas: EditingCanvasView?
    private let writer: any ImageOutputWriting
    private let floating: FloatingImageController
    private let presentPanel: (NSPanel, NSView) -> Void
    private let chooseSaveDestination: (NSPanel, @escaping (URL?) -> Void) -> Void
    var onTranslate: ((RasterImage) -> Void)?
    var onComplete: (() -> Void)?
    var isOpen: Bool { panel != nil }

    /// AppKit can order a panel out without closing it, for example when the app is hidden
    /// or deactivated. The retained canvas is no longer interactive, so release it before
    /// rejecting another capture or asking whether an edit should be discarded on quit.
    func discardHiddenSession() {
        guard let panel, !panel.isVisible else { return }
        cancel()
    }

    /// Opens an already normalized history image without replacing an active edit.
    func presentImported(image:RasterImage,decoded:CGImage,availableFrame:CGRect) -> Bool {
        guard !isOpen, decoded.width == image.width, decoded.height == image.height,
              let geometry = ImportedImagePresentation(imageSize:CGSize(width:image.width,height:image.height),availableFrame:availableFrame) else { return false }
        let session = EditingSession(image:image,decoded:decoded,canvas:geometry.canvasSize,fullScreen:true,writer:writer)
        session.viewport.fit(CGRect(origin:.zero,size:geometry.canvasSize),in:CGRect(origin:.zero,size:geometry.contentSize),canvas:geometry.canvasSize)
        let view = EditingCanvasView(session:session,selectingForTranslation:false)
        let window = EditingPanel(contentRect:CGRect(origin:.zero,size:geometry.contentSize),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.setFrameOrigin(CGPoint(x:availableFrame.midX-window.frame.width/2,y:availableFrame.midY-window.frame.height/2))
        window.title = V2L("编辑图片")
        window.isReleasedWhenClosed = false; window.level = .normal
        window.isFloatingPanel = false; window.hidesOnDeactivate = false
        window.backgroundColor = .windowBackgroundColor; window.isOpaque = true; window.hasShadow = true
        window.acceptsMouseMovedEvents = true; window.delegate = self
        mount(view,in:window)
        return true
    }

    init(writer: any ImageOutputWriting = V2SystemClipboardWriter(),
         floating: FloatingImageController = FloatingImageController(),
         chooseSaveDestination: @escaping (NSPanel, @escaping (URL?) -> Void) -> Void = { panel, completion in
        let picker = NSSavePanel()
        picker.allowedContentTypes = [.png]
        picker.nameFieldStringValue = V2L("Traylet.png")
        picker.beginSheetModal(for:panel) { result in completion(result == .OK ? picker.url : nil) }
    }, presentPanel: @escaping (NSPanel, NSView) -> Void = { window, view in
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps:true)
    }) {
        self.writer = writer; self.floating = floating
        self.presentPanel = presentPanel; self.chooseSaveDestination = chooseSaveDestination
        super.init()
    }

    /// `decoded` is the capture's own pixels for `image`, which saves decoding the PNG again.
    func present(image:RasterImage,decoded:CGImage? = nil,screen:NSScreen,initiallyFullScreen:Bool,selectingForTranslation:Bool = false) {
        present(image:image,decoded:decoded,screenFrame:screen.frame,initiallyFullScreen:initiallyFullScreen,selectingForTranslation:selectingForTranslation)
    }

    func present(image:RasterImage,decoded:CGImage? = nil,screenFrame:CGRect,initiallyFullScreen:Bool,selectingForTranslation:Bool = false) {
        cancel()
        let session = EditingSession(image:image,decoded:decoded,canvas:screenFrame.size,fullScreen:initiallyFullScreen,writer:writer)
        let view = EditingCanvasView(session:session,selectingForTranslation:selectingForTranslation)
        let window = EditingPanel(contentRect:screenFrame,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true; window.hasShadow = false
        window.acceptsMouseMovedEvents = true
        mount(view,in:window)
    }

    private func mount(_ view:EditingCanvasView,in window:EditingPanel) {
        window.contentView = view
        view.onCancel = { [weak self,weak view] in
            guard let self,let view,self.canvas === view else { return }; self.cancel()
        }
        view.onSave = { [weak self,weak view] in
            guard let self,let view,self.canvas === view else { return }; self.save()
        }
        view.onTranslate = { [weak self,weak view] in
            guard let self, let view, self.canvas === view else { return }
            // Translation takes focus itself; restoring the previous app here would steal it back and hide the new window.
            do { let result = try view.session.composite(); self.cancel(restoreFocus:false); self.onTranslate?(result) }
            catch { view.session.message = "无法合成截图；请重新框选。" }
        }
        view.onFloat = { [weak self,weak view] in
            guard let self, let view, self.canvas === view else { return }
            self.float()
        }
        panel = window; canvas = view
        presentPanel(window,view)
    }

    func windowWillClose(_ notification:Notification) {
        guard let closing = notification.object as? NSWindow, panel === closing else { return }
        canvas?.cancelViewInteraction(); canvas?.colorPanel.close()
        panel = nil; canvas = nil
        onComplete?()
    }

    func cancel(restoreFocus:Bool = true) {
        guard let old = panel else { return }
        canvas?.cancelViewInteraction()
        canvas?.colorPanel.close()
        panel = nil; canvas = nil
        old.delegate = nil
        old.orderOut(nil); old.close()
        if restoreFocus { onComplete?() }
    }

    private func save() {
        guard let panel,let canvas else { return }
        guard canvas.finishText(), canvas.session.prepareOutput() else { return }
        chooseSaveDestination(panel) { [weak self,weak canvas] url in
            guard let self,let canvas,self.canvas === canvas, let url else { return }
            if canvas.session.save(to:url) { self.cancel() }
        }
    }

    private func float() {
        guard let canvas, let panel else { return }
        guard canvas.finishText(), canvas.session.prepareOutput() else { return }
        guard let selection = canvas.session.document.selection, let cgImage = canvas.session.compositeImage() else {
            canvas.session.message = "无法合成截图；请重新框选。"
            return
        }
        floating.present(cgImage: cgImage, initialFrame: floatRect(selection: selection, window: panel))
        cancel()
    }

    /// Maps the canvas selection back onto the screen so the floating window lands exactly where
    /// the capture region was, at its on-screen size.
    private func floatRect(selection: CGRect, window: NSWindow) -> CGRect {
        let content = window.contentRect(forFrameRect: window.frame)
        let originX = window.frame.minX + content.minX + selection.minX
        let originY = window.frame.minY + content.minY + content.height - selection.maxY
        return CGRect(x: originX, y: originY, width: selection.width, height: selection.height)
    }
}

private final class EditingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
