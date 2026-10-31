import AppKit
import Combine
import SwiftUI

@MainActor final class EditingCanvasView: NSView {
    let session: EditingSession
    let colorPanel = EditingColorPanel()
    let selectingForTranslation: Bool
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    var onTranslate: (() -> Void)?
    private var observation: AnyCancellable?
    private var languageObservation: AnyCancellable?
    private var toolbar: EditingBarHost<EditingToolbar>!
    private var options: EditingBarHost<EditingOptions>!
    private var editor: EditingTextView?
    private var textForeground: EditingTextForegroundView?
    private var textToken: EditingDocument.ObjectEditToken?
    private var textTarget: UUID?
    private var textRevision: UInt64 = 0
    private var textOrigin = CGPoint.zero
    private var textStyle = EditingStyle()
    private var compositeImage: NSImage?
    private let backdrop: NSImage
    private var compositeVersion: UInt64?
    private var preview: EditingMark?
    private var pointer: CGPoint?
    private var lastGesturePoint: CGPoint?
    private var track: NSTrackingArea?
    private enum Drag { case selection(CGPoint), move(CGPoint, CGRect), resize(EditingDocument.Handle, CGSize), mark, object(CGPoint, EditingDocument.ObjectEditToken), pan(CGPoint) }
    private var drag: Drag?
    private var holdingSpace = false
    /// What the last invalidation covered; drags repaint only the area that actually changed.
    private struct Drawn: Equatable { var selection: CGRect?; var marks = 0; var selectedMarkID: UUID?; var version: UInt64 = 0; var tool: EditingTool?; var message = ""; var brush: CGFloat = 0; var viewport = EditingViewport() }
    private var drawn = Drawn()
    private var previewDamage = CGRect.null
    private var adjustingSelection: Bool {
        switch drag { case .move, .resize: true; default: false }
    }
    /// Frames of the toolbar and its option bar, for layout checks.
    var barFrames: (toolbar:CGRect,options:CGRect) { (toolbar.frame,options.frame) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(session:EditingSession,selectingForTranslation:Bool) {
        self.session = session; self.selectingForTranslation = selectingForTranslation
        // Decode the screenshot once; drawing must never re-decode PNG data.
        backdrop = session.sourceImage.map { NSImage(cgImage:$0,size:session.document.canvas) } ?? NSImage(size:session.document.canvas)
        super.init(frame:CGRect(origin:.zero,size:session.document.canvas))
        toolbar = EditingBarHost(rootView:EditingToolbar(session:session,translationMode:selectingForTranslation,copy:{ [weak self] in self?.copyAndClose() },save:{ [weak self] in self?.onSave?() },translate:{ [weak self] in self?.onTranslate?() },drag:{ [weak self] total,ended in self?.dragToolbar(total,ended:ended) },reset:{ [weak self] in self?.resetToolbar() },finishText:{ [weak self] in self?.finishText() ?? false },fitView:{ [weak self] in self?.fitSelection() },resetView:{ [weak self] in self?.resetView() }))
        toolbar.sizingOptions = [.intrinsicContentSize]
        options = EditingBarHost(rootView:EditingOptions(session:session,colorPanel:colorPanel))
        options.sizingOptions = [.intrinsicContentSize]
        addSubview(toolbar); addSubview(options)
        observation = session.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.invalidateSession() }
        }
        updateLocalizedAccessibility()
        languageObservation = V2Localization.shared.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateLocalizedAccessibility(); self?.needsDisplay = true
            }
        }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name:NSWindow.didResignKeyNotification, object:nil)
        NotificationCenter.default.removeObserver(self, name:NSApplication.didResignActiveNotification, object:nil)
        cancelViewInteraction()
        if let window {
            NotificationCenter.default.addObserver(self, selector:#selector(lostFocus), name:NSWindow.didResignKeyNotification, object:window)
            NotificationCenter.default.addObserver(self, selector:#selector(lostFocus), name:NSApplication.didResignActiveNotification, object:nil)
        }
    }
    @objc private func lostFocus(_ notification: Notification) {
        if notification.name == NSWindow.didResignKeyNotification, colorPanel.isManagingColorWell { return }
        cancelViewInteraction(preservingSelection:true)
    }
    override func resignFirstResponder() -> Bool {
        holdingSpace = false
        if case .pan = drag { drag = nil }
        return super.resignFirstResponder()
    }
    func cancelViewInteraction(preservingSelection:Bool = false) {
        // A live first selection is provisional until mouseUp. Losing focus must not leave it
        // exportable, and a later mouseUp must not complete a translation capture accidentally.
        cancelText()
        if case .selection = drag { session.document.discardUnfinishedSelection() }
        session.invalidateStyleEditing(); session.document.cancelObjectEdit()
        if !preservingSelection { session.document.selectMark(nil) }
        session.didEndObjectMove()
        holdingSpace = false; drag = nil; preview = nil; previewDamage = .null; pointer = nil; lastGesturePoint = nil
        needsDisplay = true; needsLayout = true
    }
    private func fitSelection() {
        guard drag == nil, finishText(), let selection = session.document.selection else { return }
        // Reserve room for the fixed-size controls below the fitted selection.
        let available = CGRect(x:24, y:24, width:max(1,bounds.width-48), height:max(1,bounds.height-128))
        session.viewport.fit(selection, in:available, canvas:session.document.canvas)
        needsDisplay = true; needsLayout = true
    }
    private func resetView() {
        guard drag == nil, finishText() else { return }
        session.viewport.reset(); needsDisplay = true; needsLayout = true
    }

    /// A successful copy ends the capture; failures keep the edit open with the message.
    private func copyAndClose() {
        guard finishText() else { return }
        if session.copy() { onCancel?() }
    }
    private var toolbarDragStart: CGPoint?
    private var customToolbarOrigin: CGPoint?
    private func resetToolbar() {
        customToolbarOrigin = nil; session.document.resetToolbar(); needsLayout = true
    }
    private func barOrigin(_ point:CGPoint,size:CGSize) -> CGPoint {
        CGPoint(x:max(bounds.minX+4,min(bounds.maxX-size.width-4,point.x)),
                y:max(bounds.minY+4,min(bounds.maxY-size.height-4,point.y)))
    }
    private func optionsOrigin(toolbar:CGRect,size:CGSize) -> CGPoint {
        let below = toolbar.maxY+8
        return CGPoint(x:max(bounds.minX+4,min(bounds.maxX-size.width-4,toolbar.minX)),
            y:below+size.height <= bounds.maxY-4 ? below : max(bounds.minY+4,toolbar.minY-size.height-8))
    }
    /// Moves the bars directly during a drag; the document is committed once at the end, so no full redraw runs per event.
    private func dragToolbar(_ total:CGSize,ended:Bool) {
        let start = toolbarDragStart ?? toolbar.frame.origin; toolbarDragStart = start
        let origin = barOrigin(CGPoint(x:start.x+total.width,y:start.y+total.height),size:toolbar.frame.size)
        toolbar.frame.origin = origin
        options.frame.origin = optionsOrigin(toolbar:toolbar.frame,size:options.frame.size)
        if ended { toolbarDragStart = nil; customToolbarOrigin = origin; session.document.dragToolbar(to:origin) }
    }
    private func selectionDamage(_ selection:CGRect?) -> CGRect {
        guard let selection else { return .null }
        let r = session.viewport.viewRect(selection)
        // Border, handles and the size label above the region.
        return interactionRect(r).insetBy(dx:-12,dy:-12).union(CGRect(x:r.minX-4,y:r.minY-30,width:200,height:30))
    }
    /// A moved or resized region repaints only its old and new areas; anything else repaints the whole canvas.
    private func invalidateSession() {
        if editor != nil, !textContextIsValid { cancelText() }
        let now = Drawn(selection:session.document.selection,marks:session.document.marks.count,selectedMarkID:session.document.selectedMarkID,version:session.document.renderVersion,tool:session.tool,message:session.message,brush:session.style.brushSize,viewport:session.viewport)
        guard now != drawn else { return }
        var others = now; others.selection = drawn.selection
        if others == drawn, let old = drawn.selection, let new = now.selection {
            let oldView = session.viewport.viewRect(old), newView = session.viewport.viewRect(new)
            if min(oldView.width,oldView.height,newView.width,newView.height) < 32 {
                // The tiny-selection label can switch sides and its toolbar can flip together; repaint both old display overlays.
                needsDisplay = true
            } else { setNeedsDisplay(selectionDamage(old).union(selectionDamage(new))) }
        } else { needsDisplay = true }
        needsLayout = true
        textForeground?.needsDisplay = true
        drawn = now
    }
    private func markDamage(_ mark:EditingMark) -> CGRect {
        guard let r = session.document.selection, let first = mark.points.first else { return .null }
        let box = mark.points.reduce(CGRect(origin:first,size:.zero)) { $0.union(CGRect(origin:$1,size:.zero)) }
        // Line width, arrow head and blur outline all stay within this margin.
        let pad = mark.tool == .number ? EditingNumberBadge.bounds(mark).width/2+4 : max(mark.style.brushSize/2+4,10+mark.style.width*3)
        return session.viewport.viewRect(box.offsetBy(dx:r.minX,dy:r.minY).insetBy(dx:-pad,dy:-pad))
    }
    private func updateLocalizedAccessibility() {
        setAccessibilityLabel(V2L("截图编辑区域"))
        setAccessibilityHelp(V2L("拖动框选。未选择工具时拖动选区移动，八个圆点调整大小。Escape 退出。") + " " + V2L("方向键移动 1 像素，Shift 移动 10 像素，Command 调整宽高。") + " " + V2L("适配选区") + " ⌘2 · " + V2L("重置视图") + " ⌘0 · " + V2L("按住空格拖动平移") + " " + V2L("拖动所选标注移动；方向键微调，Shift 为 10 像素。"))
    }

    override func layout() {
        super.layout()
        textForeground?.frame = bounds
        // The capsule is the hosting view's own size, so its visible left edge is exactly the frame edge the option bar aligns to.
        let size = CGSize(width:min(max(60,toolbar.intrinsicContentSize.width),max(0,bounds.width-8)),height:36)
        toolbar.frame = CGRect(origin:session.document.toolbarOrigin(size:size),size:size)
        if let customToolbarOrigin {
            toolbar.frame.origin = barOrigin(customToolbarOrigin,size:size)
        } else if session.viewport != EditingViewport(), toolbarDragStart == nil {
            let selected = session.document.selection.map(session.viewport.viewRect) ?? bounds
            toolbar.frame.origin = CGPoint(x:max(4,min(bounds.width-size.width-4,selected.maxX-size.width)),
                y:max(4,min(bounds.height-size.height-4,selected.maxY+10)))
        }
        // A 1px crop must not put its enlarged handles underneath the automatic toolbar.
        if customToolbarOrigin == nil, let selected = session.document.selection {
            let r = session.viewport.viewRect(selected)
            if r.width < 32 || r.height < 32 {
                let interaction = interactionRect(r)
                let stackHeight:CGFloat = session.tool == nil || session.tool == .redaction ? 36 : 80
                let y = interaction.maxY+26+stackHeight <= bounds.maxY-4 ? interaction.maxY+26 : interaction.minY-26-stackHeight
                toolbar.frame.origin = barOrigin(CGPoint(x:interaction.maxX-size.width,y:y),size:size)
            }
        }
        // Width fits the active tool's controls; the bar shares the toolbar's height and left edge.
        // intrinsicContentSize tracks the current tool's controls; a stale fitting size would leave the capsule off the left edge.
        let optionSize = CGSize(width:min(max(60,options.intrinsicContentSize.width),max(0,bounds.width-8)),height:toolbar.frame.height)
        options.frame = CGRect(origin:optionsOrigin(toolbar:toolbar.frame,size:optionSize),size:optionSize)
        // Translation capture starts as soon as the region is chosen, so it has no toolbar.
        toolbar.isHidden = session.document.selection == nil || selectingForTranslation
        options.isHidden = session.tool == nil || session.tool == .redaction || selectingForTranslation || toolbar.isHidden
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let track { removeTrackingArea(track) }
        let area = NSTrackingArea(rect:.zero,options:[.activeInKeyWindow,.mouseMoved,.mouseEnteredAndExited,.cursorUpdate,.inVisibleRect],owner:self,userInfo:nil)
        track = area; addTrackingArea(area)
    }
    override func draw(_ dirtyRect:NSRect) {
        super.draw(dirtyRect)
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        NSGraphicsContext.current?.saveGraphicsState()
        let context = NSGraphicsContext.current?.cgContext
        context?.translateBy(x:session.viewport.offset.x,y:session.viewport.offset.y)
        context?.scaleBy(x:session.viewport.scale,y:session.viewport.scale)
        let canvasBounds = CGRect(origin:.zero,size:session.document.canvas)
        backdrop.draw(in:canvasBounds,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
        let shade = NSBezierPath(rect:canvasBounds)
        if let r = session.document.selection { shade.appendRect(r); shade.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.5).setFill(); shade.fill()
        if let selection = session.document.selection { drawMarks(in:selection) }
        NSGraphicsContext.current?.restoreGraphicsState()
        if editor == nil { drawSelectionOverlay() }
    }
    /// Crop borders, handles and labels remain above annotations even while a native draft is active.
    private func drawSelectionOverlay() {
        guard let selection = session.document.selection else {
            (V2L("拖动选择截图区域 · Esc 退出") as NSString).draw(at:CGPoint(x:24,y:24),withAttributes:[.font:NSFont.systemFont(ofSize:16),.foregroundColor:NSColor.white])
            return
        }
        let r = session.viewport.viewRect(selection)
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect:r); border.lineWidth = 1; border.stroke()
        let interaction = r.width < 32 || r.height < 32 ? interactionRect(r) : r
        if interaction != r {
            let guide = NSBezierPath(rect:interaction); guide.lineWidth = 0.5
            guide.setLineDash([2,3],count:2,phase:0); guide.stroke()
        }
        for (_,p) in interactionHandles(r) {
            let circle = NSBezierPath(ovalIn:CGRect(x:p.x-4,y:p.y-4,width:8,height:8))
            NSColor.white.setFill(); circle.fill(); NSColor.controlAccentColor.setStroke(); circle.stroke()
        }
        let label = selectionDimensionLabel
        let labelPoint = selectionLabelFrame.origin
        let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize:12,weight:.medium),.foregroundColor:NSColor.labelColor,.backgroundColor:NSColor.controlBackgroundColor]
        (label as NSString).draw(at:labelPoint,withAttributes:attributes)
        // The brush ring exists only under the pointer, inside the region and away from the bars.
        if session.tool == .blur, let p = pointer, r.contains(p), !overBars(p) {
            let d = session.style.brushSize * session.viewport.scale
            NSGraphicsContext.current?.saveGraphicsState(); NSBezierPath(rect:r).addClip()
            let ring = NSBezierPath(ovalIn:CGRect(x:p.x-d/2,y:p.y-d/2,width:d,height:d))
            NSColor.white.setStroke(); ring.lineWidth = 2; ring.stroke()
            NSColor.black.setStroke(); ring.lineWidth = 1; ring.stroke()
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        if !session.message.isEmpty {
            (session.message as NSString).draw(at:CGPoint(x:16,y:16),withAttributes:attributes)
        }
    }
    /// Cache the blurred screenshot alone; highlight and foreground layers remain independently ordered during previews.
    private func drawMarks(in r:CGRect) {
        let marks = session.document.marks
        guard !marks.isEmpty || preview != nil, let context = NSGraphicsContext.current?.cgContext else { return }
        // While the region is being moved or resized, blur waits for release instead of re-running every mouse event.
        let hasBlur = marks.contains { $0.tool == .blur } && !(adjustingSelection && compositeVersion != session.document.blurSourceVersion)
        if hasBlur {
            if compositeImage == nil || compositeVersion != session.document.blurSourceVersion {
                compositeImage = session.blurredSourceImage().map { NSImage(cgImage:$0,size:r.size) }
                compositeVersion = session.document.blurSourceVersion
            }
            compositeImage?.draw(in:r,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
        }
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to:r); context.translateBy(x:r.minX,y:r.minY)
        let local = CGRect(origin:.zero,size:r.size)
        for mark in marks where mark.tool == .highlight { EditingRenderer.drawLive(mark,in:context,bounds:local) }
        if let preview, preview.tool == .highlight { EditingRenderer.drawLive(preview,in:context,bounds:local) }
        // During native text editing the later ordinary foreground belongs to one full-canvas
        // sibling above the editor, including portions outside the editor's wrapping frame.
        let foregroundStart = textTarget.flatMap { target in marks.firstIndex { $0.id == target } } ?? marks.count
        for mark in marks.prefix(foregroundStart) where mark.tool != .highlight { EditingRenderer.drawLive(mark,in:context,bounds:local) }
        if let preview {
            if preview.tool == .blur {
                // Outline only: a fill here would wash out the colors of shapes already drawn under the brush.
                let diameter = max(8,min(60,preview.style.brushSize))
                let outline: CGPath
                if preview.points.count == 1, let p = preview.points.first { outline = CGPath(ellipseIn:CGRect(x:p.x-diameter/2,y:p.y-diameter/2,width:diameter,height:diameter),transform:nil) }
                else {
                    let line = CGMutablePath(); line.addLines(between:preview.points)
                    outline = line.copy(strokingWithWidth:diameter,lineCap:.round,lineJoin:.round,miterLimit:1)
                }
                context.addPath(outline); context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(2); context.strokePath()
            } else if preview.tool != .highlight { EditingRenderer.drawLive(preview,in:context,bounds:local) }
        }
        if let mark = session.document.selectedMark, session.tool == mark.tool, mark.id != textTarget {
            context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1/session.viewport.scale)
            context.setLineDash(phase:0,lengths:[3/session.viewport.scale,3/session.viewport.scale])
            let box = (mark.tool == .text ? EditingTextLayout.bounds(mark,in:local) : EditingObjectGeometry.bounds(mark)).insetBy(dx:-3,dy:-3)
            if mark.tool == .number { context.strokeEllipse(in:box) } else { context.stroke(box) }
            context.setLineDash(phase:0,lengths:[])
        }
        if editor == nil {
            EditingRenderer.drawRedactionsLive(document:session.document,imageSize:CGSize(width:session.image.width,height:session.image.height),preview:preview,in:context)
        }
    }
    private var selectionDimensionLabel: String {
        let pixels = session.document.pixelBounds(imageSize:CGSize(width:session.image.width,height:session.image.height)) ?? .zero
        return "\(Int(pixels.width)) × \(Int(pixels.height))"
    }
    /// Display-only label frame, kept on screen and clear of the eight tiny-selection handles.
    var selectionLabelFrame: CGRect {
        guard let selection = session.document.selection else { return .zero }
        let r = session.viewport.viewRect(selection)
        let size = (selectionDimensionLabel as NSString).size(withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:12,weight:.medium)])
        var point = CGPoint(x:r.minX+4,y:r.minY >= 25 ? r.minY-23 : r.minY+6)
        if r.width < 32 || r.height < 32 {
            let frame = interactionRect(r)
            if frame.maxX+6+size.width <= bounds.maxX-4 { point = CGPoint(x:frame.maxX+6,y:frame.minY+4) }
            else if frame.minX-6-size.width >= bounds.minX+4 { point = CGPoint(x:frame.minX-6-size.width,y:frame.minY+4) }
            else { point = CGPoint(x:frame.minX+4,y:frame.minY-size.height-6 >= bounds.minY+4 ? frame.minY-size.height-6 : frame.maxY+6) }
        }
        point.x = max(bounds.minX+4,min(bounds.maxX-size.width-4,point.x))
        point.y = max(bounds.minY+4,min(bounds.maxY-size.height-4,point.y))
        if r.width < 32 || r.height < 32 {
            let bars = [toolbar,options].compactMap { bar -> CGRect? in
                guard let bar, !bar.isHidden else { return nil }; return bar.frame
            }
            if bars.contains(where:{ $0.intersects(CGRect(origin:point,size:size)) }) {
                let below = (bars.map(\.maxY).max() ?? 0)+6
                let above = (bars.map(\.minY).min() ?? 0)-size.height-6
                point.y = below+size.height <= bounds.maxY-4 ? below : max(bounds.minY+4,above)
            }
        }
        return CGRect(origin:point,size:size)
    }
    private func handles(_ r:CGRect) -> [(EditingDocument.Handle,CGPoint)] {
        [(.northWest,CGPoint(x:r.minX,y:r.minY)),(.north,CGPoint(x:r.midX,y:r.minY)),(.northEast,CGPoint(x:r.maxX,y:r.minY)),(.east,CGPoint(x:r.maxX,y:r.midY)),(.southEast,CGPoint(x:r.maxX,y:r.maxY)),(.south,CGPoint(x:r.midX,y:r.maxY)),(.southWest,CGPoint(x:r.minX,y:r.maxY)),(.west,CGPoint(x:r.minX,y:r.midY))]
    }
    /// Enlarges only interaction geometry, never the selection or output pixels.
    private func interactionRect(_ r:CGRect) -> CGRect {
        let width = min(max(32,r.width),max(1,bounds.width-10)), height = min(max(32,r.height),max(1,bounds.height-10))
        return CGRect(x:max(bounds.minX+5,min(bounds.maxX-width-5,r.midX-width/2)),
                      y:max(bounds.minY+5,min(bounds.maxY-height-5,r.midY-height/2)),width:width,height:height)
    }
    private func interactionHandles(_ r:CGRect) -> [(EditingDocument.Handle,CGPoint)] {
        let target = r.width < 32 || r.height < 32 ? interactionRect(r) : r
        return handles(target).map { handle,p in
            (handle,CGPoint(x:max(bounds.minX+4,min(bounds.maxX-4,p.x)),y:max(bounds.minY+4,min(bounds.maxY-4,p.y))))
        }
    }
    private func hitHandle(_ p:CGPoint, selection:CGRect) -> EditingDocument.Handle? {
        let candidates = interactionHandles(selection)
        return candidates.enumerated().filter { hypot($0.element.1.x-p.x,$0.element.1.y-p.y) <= 9 }
            .min { lhs,rhs in
                let l = hypot(lhs.element.1.x-p.x,lhs.element.1.y-p.y)
                let r = hypot(rhs.element.1.x-p.x,rhs.element.1.y-p.y)
                return l == r ? lhs.offset < rhs.offset : l < r
            }?.element.0
    }
    override func mouseDown(with event:NSEvent) {
        let viewPoint = convert(event.locationInWindow,from:nil)
        lastGesturePoint = viewPoint
        if holdingSpace, editor == nil {
            drag = .pan(viewPoint); NSCursor.closedHand.set(); return
        }
        guard finishText() else { return }; window?.makeFirstResponder(self)
        let p = session.viewport.canvasPoint(viewPoint); pointer = viewPoint
        if let r = session.document.selection {
            let displayed = session.viewport.viewRect(r)
            if let handle = hitHandle(viewPoint,selection:displayed), let actual = handles(r).first(where: { $0.0 == handle })?.1 {
                drag = .resize(handle,CGSize(width:actual.x-p.x,height:actual.y-p.y)); return
            }
            let extendedMove = (session.tool == nil || selectingForTranslation) && (displayed.width < 32 || displayed.height < 32) && interactionRect(displayed).contains(viewPoint)
            if r.contains(p) || extendedMove {
                guard let tool = session.tool, !selectingForTranslation else { drag = .move(p,r); return }
                let local = CGPoint(x:p.x-r.minX,y:p.y-r.minY)
                if tool == .text {
                    let existing = session.document.marks.reversed().first { $0.tool == .text && EditingTextLayout.contains(local,mark:$0,in:CGRect(origin:.zero,size:r.size)) }
                    session.selectObject(existing?.id)
                    if let existing {
                        if event.clickCount >= 2 { beginText(at:existing.points[0],existing:existing) }
                        else if let token = session.document.beginObjectEdit(.move) { drag = .object(p,token) }
                    } else { beginText(at:local) }
                    needsDisplay = true; return
                }
                if tool == .number || tool == .arrow {
                    let existing = session.document.marks.reversed().first { $0.tool == tool && EditingObjectGeometry.contains(local,mark:$0,viewScale:session.viewport.scale) }
                    session.selectObject(existing?.id)
                    if existing != nil, let token = session.document.beginObjectEdit(.move) {
                        drag = .object(p,token); needsDisplay = true; return
                    }
                }
                var mark = EditingMark(tool:tool,points:[local],style:session.style)
                if tool == .number { mark.number = session.document.nextNumber }
                preview = mark; drag = .mark
                previewDamage = markDamage(mark); setNeedsDisplay(previewDamage); return
            }
        }
        // A new selection is only started before the first region exists; outside clicks preserve edits.
        if session.document.selection == nil, CGRect(origin:.zero,size:session.document.canvas).contains(p) { drag = .selection(p) }
    }
    override func mouseDragged(with event:NSEvent) {
        let viewPoint = convert(event.locationInWindow,from:nil)
        if drag != nil { lastGesturePoint = viewPoint }
        let p = session.document.clamp(session.viewport.canvasPoint(viewPoint)); pointer = viewPoint
        switch drag {
        case .pan(let last):
            session.viewport.pan(by:CGSize(width:viewPoint.x-last.x,height:viewPoint.y-last.y),in:bounds,canvas:session.document.canvas)
            drag = .pan(viewPoint); needsDisplay = true; needsLayout = true
        case .selection(let start): session.document.selectLive(from:start,to:p)
        case .move(let start, let original):
            if let current = session.document.selection {
                // The display-only move halo can begin outside the image. Clamp the resulting crop, not either gesture endpoint.
                let raw = session.viewport.canvasPoint(viewPoint)
                session.document.moveSelection(by:CGSize(width:original.minX+raw.x-start.x-current.minX,height:original.minY+raw.y-start.y-current.minY))
            }
        case .resize(let handle, let offset):
            let raw = session.viewport.canvasPoint(viewPoint)
            session.document.resizeSelection(handle,to:CGPoint(x:raw.x+offset.width,y:raw.y+offset.height))
        case .object(let start,let token):
            let raw = session.viewport.canvasPoint(viewPoint)
            _ = session.document.moveObject(token,totalCanvasDelta:CGSize(width:raw.x-start.x,height:raw.y-start.y))
        case .mark:
            guard let r = session.document.selection,var mark = preview else { return }
            let local = CGPoint(x:max(0,min(r.width,p.x-r.minX)),y:max(0,min(r.height,p.y-r.minY)))
            if mark.tool == .number {
                // Placement is a click. An intentional drag cancels it without consuming a number.
                if hypot(local.x-mark.points[0].x,local.y-mark.points[0].y)*session.viewport.scale > 4 {
                    preview = nil; setNeedsDisplay(previewDamage); previewDamage = .null
                }
                return
            }
            if mark.tool == .pencil || mark.tool == .blur { mark.points.append(local) }
            else { mark.points = [mark.points[0],local] }
            preview = mark
            let damage = markDamage(mark)
            setNeedsDisplay(previewDamage.union(damage)); previewDamage = damage
        case nil: break
        }
        updateCursor(at:viewPoint); invalidateSession()
    }
    override func mouseUp(with event:NSEvent) {
        // AppKit can coalesce the last drag event. Commit the release position before closing the gesture.
        let release = convert(event.locationInWindow,from:nil)
        defer { lastGesturePoint = nil }
        if drag != nil, lastGesturePoint != release { mouseDragged(with:event) }
        if case .pan = drag {
            drag = nil; updateCursor(at:convert(event.locationInWindow,from:nil)); return
        }
        if case .object(_,let token) = drag {
            _ = session.document.commitObjectEdit(token); session.didEndObjectMove(); drag = nil; needsDisplay = true; return
        }
        if case .selection = drag {
            drag = nil
            let kept = session.document.finishSelection()
            needsDisplay = true; needsLayout = true
            if kept, selectingForTranslation { onTranslate?() }
            return
        }
        if let mark = preview {
            let first = mark.points.first!,last = mark.points.last!
            if mark.tool == .number || mark.tool == .pencil || mark.tool == .blur || mark.tool == .redaction || mark.tool == .highlight || hypot(first.x-last.x,first.y-last.y) >= 2 { session.document.append(mark) }
        }
        preview = nil; previewDamage = .null; drag = nil; needsDisplay = true; updateCursor(at:convert(event.locationInWindow,from:nil))
    }
    override func mouseMoved(with event:NSEvent) {
        let old = pointer, new = convert(event.locationInWindow,from:nil); pointer = new
        updateCursor(at:new)
        // Only the blur brush ring follows the pointer; everything else stays untouched while hovering.
        guard session.tool == .blur else { return }
        let pad = session.style.brushSize * session.viewport.scale/2+4
        for point in [old,new].compactMap({ $0 }) { setNeedsDisplay(CGRect(x:point.x-pad,y:point.y-pad,width:pad*2,height:pad*2)) }
    }
    override func mouseEntered(with event:NSEvent) { updateCursor(at:convert(event.locationInWindow,from:nil)) }
    override func cursorUpdate(with event:NSEvent) { updateCursor(at:convert(event.locationInWindow,from:nil)) }
    override func mouseExited(with event:NSEvent) {
        pointer = nil
        if session.tool == .blur { needsDisplay = true }
    }
    private func overBars(_ p:CGPoint) -> Bool {
        (!toolbar.isHidden && toolbar.frame.contains(p)) || (!options.isHidden && options.frame.contains(p))
    }
    private func updateCursor(at p:CGPoint) { cursor(at:p).set() }
    func cursor(at p:CGPoint) -> NSCursor {
        if overBars(p) { return .arrow }
        switch drag {
        case .pan: return .closedHand
        case .resize(let handle, _): return Self.cursor(for:handle)
        case .move, .object: return .closedHand
        case .selection, .mark: return .crosshair
        case nil: break
        }
        if holdingSpace { return .openHand }
        guard let selection = session.document.selection else { return .crosshair }
        let r = session.viewport.viewRect(selection)
        if let handle = hitHandle(p,selection:r) { return Self.cursor(for:handle) }
        if (r.width < 32 || r.height < 32), (session.tool == nil || selectingForTranslation), interactionRect(r).contains(p) { return .openHand }
        guard r.contains(p) else { return .arrow }
        if selectingForTranslation { return .openHand }
        if session.tool == .text {
            let p = session.viewport.canvasPoint(p), local = CGPoint(x:p.x-selection.minX,y:p.y-selection.minY)
            if session.document.marks.reversed().contains(where:{ $0.tool == .text && EditingTextLayout.contains(local,mark:$0,in:CGRect(origin:.zero,size:selection.size)) }) { return .openHand }
        }
        if let tool = session.tool, tool == .number || tool == .arrow {
            let local = session.viewport.canvasPoint(p)
            if session.document.marks.reversed().contains(where:{ $0.tool == tool && EditingObjectGeometry.contains(CGPoint(x:local.x-selection.minX,y:local.y-selection.minY),mark:$0,viewScale:session.viewport.scale) }) { return .openHand }
        }
        switch session.tool { case nil: return .openHand; case .text: return .iBeam; default: return .crosshair }
    }
    private static func cursor(for handle:EditingDocument.Handle) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch handle {
        case .northWest: position = .topLeft
        case .north: position = .top
        case .northEast: position = .topRight
        case .east: position = .right
        case .southEast: position = .bottomRight
        case .south: position = .bottom
        case .southWest: position = .bottomLeft
        case .west: position = .left
        }
        return NSCursor.frameResize(position:position,directions:.all)
    }
    override func keyDown(with event:NSEvent) {
        // Text views (including a field editor in tool options) retain their own shortcuts and IME.
        guard editor == nil, !(window?.firstResponder is NSTextView) else { return }
        if event.keyCode == 36, drag == nil, session.tool == .text, let mark = session.document.selectedMark, mark.tool == .text {
            beginText(at:mark.points[0],existing:mark); return
        }
        if event.keyCode == 53 {
            if case .object = drag {
                session.document.cancelObjectEdit(); session.didEndObjectMove(); drag = nil; lastGesturePoint = nil; needsDisplay = true; return
            }
            cancelViewInteraction()
            onCancel?(); return
        }
        if [51,117].contains(event.keyCode), drag == nil, (session.tool == .number || session.tool == .arrow || session.tool == .text),
           event.modifierFlags.intersection([.command,.control,.option]).isEmpty {
            _ = session.document.deleteSelectedMark(); needsDisplay = true; return
        }
        if event.keyCode == 49, event.modifierFlags.intersection([.command,.control,.option]).isEmpty {
            if drag == nil { holdingSpace = true; NSCursor.openHand.set() }
            return
        }
        if editor == nil, drag == nil, session.document.selection != nil,
           event.modifierFlags.intersection([.control, .option]).isEmpty {
            let direction: EditingDocument.NudgeDirection?
            switch event.keyCode {
            case 123: direction = .left
            case 124: direction = .right
            case 125: direction = .down
            case 126: direction = .up
            default: direction = nil
            }
            if let direction {
                if session.document.selectedMark != nil, !event.modifierFlags.contains(.command) {
                    _ = session.document.nudgeSelectedObject(direction,accelerated:event.modifierFlags.contains(.shift)); return
                }
                var document = session.document
                if document.nudgeSelection(direction, imageSize: CGSize(width: session.image.width, height: session.image.height),
                    accelerated: event.modifierFlags.contains(.shift), resizing: event.modifierFlags.contains(.command)) {
                    session.document = document
                }
                return
            }
        }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "2": fitSelection(); return
            case "0": resetView(); return
            case "z": event.modifierFlags.contains(.shift) ? session.document.redo() : session.document.undo(); return
            case "c": copyAndClose(); return
            case "s": onSave?(); return
            default: break
            }
        }
        if selectingForTranslation && event.keyCode == 36 { onTranslate?(); return }
        super.keyDown(with:event)
    }
    override func keyUp(with event:NSEvent) {
        if event.keyCode == 49 {
            holdingSpace = false
            if case .pan = drag { drag = nil }
            updateCursor(at:pointer ?? .zero); return
        }
        super.keyUp(with:event)
    }
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        guard editor == nil, !(window?.firstResponder is NSTextView),
              event.modifierFlags.intersection([.command,.control,.option,.shift]) == .command,
              ["0","2"].contains(event.charactersIgnoringModifiers ?? "") else { return super.performKeyEquivalent(with:event) }
        keyDown(with:event); return true
    }
    private func beginText(at local:CGPoint,existing:EditingMark? = nil) {
        guard let r = session.document.selection else { return }
        session.finishStyleEditing()
        textOrigin = local; textStyle = existing?.style ?? session.style; textTarget = existing?.id
        textToken = existing == nil ? nil : session.document.beginObjectEdit(.text)
        textRevision = session.document.objectContextRevision
        let textBounds = CGRect(x:r.minX+local.x,y:r.minY+local.y,width:max(1,existing?.textWidth ?? (r.width-local.x)),height:max(1,r.height-local.y))
        let text = EditingTextView(frame:session.viewport.viewRect(textBounds))
        text.bounds = CGRect(origin:.zero,size:textBounds.size)
        text.font = .systemFont(ofSize:textStyle.fontSize,weight:.semibold)
        text.textColor = textStyle.color; text.drawsBackground = false
        text.isRichText = false; text.isAutomaticQuoteSubstitutionEnabled = false; text.allowsUndo = true
        text.isVerticallyResizable = false; text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true; text.textContainer?.heightTracksTextView = true
        text.textContainerInset = .zero; text.textContainer?.lineFragmentPadding = 0
        text.string = existing?.text ?? ""
        text.drawingClip = CGRect(x:-local.x,y:-local.y,width:r.width,height:r.height).intersection(text.bounds)
        let foreground = EditingTextForegroundView(frame:bounds)
        foreground.drawContents = { [weak self,weak text] context in
            guard let self, self.editor === text, let crop = self.session.document.selection else { return }
            context.saveGState()
            context.translateBy(x:self.session.viewport.offset.x,y:self.session.viewport.offset.y)
            context.scaleBy(x:self.session.viewport.scale,y:self.session.viewport.scale)
            context.clip(to:crop); context.translateBy(x:crop.minX,y:crop.minY)
            let document = self.session.document, bounds = CGRect(origin:.zero,size:crop.size)
            if let target = self.textTarget, let index = document.marks.firstIndex(where:{ $0.id == target }) {
                for mark in document.marks.dropFirst(index+1) where mark.tool != .highlight {
                    EditingRenderer.drawLive(mark,in:context,bounds:bounds)
                }
            }
            EditingRenderer.drawRedactionsLive(document:document,imageSize:CGSize(width:self.session.image.width,height:self.session.image.height),preview:nil,in:context)
            context.restoreGState()
            self.drawSelectionOverlay()
        }
        text.onFinish = { [weak self,weak text] in guard let self, self.editor === text else { return }; _ = self.finishText() }
        text.onCancel = { [weak self,weak text] in guard let self, self.editor === text else { return }; self.cancelText() }
        editor = text; session.isEditingText = true
        textForeground = foreground
        addSubview(text,positioned:.below,relativeTo:toolbar)
        addSubview(foreground,positioned:.above,relativeTo:text)
        window?.makeFirstResponder(text); needsDisplay = true
    }
    private var textContextIsValid: Bool {
        guard session.tool == .text else { return false }
        if let token = textToken { return session.document.isObjectEditActive(token) }
        return textRevision == session.document.objectContextRevision
    }
    func cancelText() {
        guard let text = editor else { return }
        editor = nil; text.onFinish = nil; text.onCancel = nil
        textForeground?.drawContents = nil; textForeground?.removeFromSuperview(); textForeground = nil
        if let token = textToken, session.document.isObjectEditActive(token) { session.document.cancelObjectEdit() }
        textToken = nil; textTarget = nil; session.isEditingText = false; session.didEndTextEditing()
        text.removeFromSuperview(); if window?.firstResponder === text { window?.makeFirstResponder(self) }
        needsDisplay = true
    }
    @discardableResult func finishText() -> Bool {
        guard let text = editor else { return true }
        guard textContextIsValid else { cancelText(); return true }
        guard !text.hasMarkedText() else { session.message = "请先完成文字输入。"; return false }
        let value = text.string, token = textToken
        editor = nil; text.onFinish = nil; text.onCancel = nil
        textForeground?.drawContents = nil; textForeground?.removeFromSuperview(); textForeground = nil
        textToken = nil; textTarget = nil; session.isEditingText = false; session.message = ""
        if let token {
            _ = session.document.textObject(token,text:value); _ = session.document.commitObjectEdit(token)
        } else if !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            session.document.append(EditingMark(tool:.text,points:[textOrigin],style:textStyle,text:value))
        }
        text.removeFromSuperview(); window?.makeFirstResponder(self); needsDisplay = true
        return true
    }
}

/// One transparent foreground pass above the native draft; it never owns input or focus.
private final class EditingTextForegroundView: NSView {
    var drawContents: ((CGContext) -> Void)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect:NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawContents?(context)
    }
}

private final class EditingTextView: NSTextView {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var drawingClip = CGRect.zero
    override func draw(_ dirtyRect:NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to:drawingClip)
        super.draw(dirtyRect)
    }
    override func hitTest(_ point:NSPoint) -> NSView? {
        guard drawingClip.contains(convert(point,from:superview)) else { return nil }
        return super.hitTest(point)
    }
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 53 {
            switch EditingDocument.escapeAction(isEditingText:true,hasMarkedText:hasMarkedText()) {
            case .inputMethod: super.keyDown(with:event)
            case .cancelText: onCancel?()
            case .close: break
            }
            return
        }
        if event.keyCode == 36, event.modifierFlags.contains(.command) { onFinish?(); return }
        super.keyDown(with:event)
    }
}

/// Hosting view that asks its container to lay out again whenever the SwiftUI content changes size.
final class EditingBarHost<Content: View>: NSHostingView<Content> {
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }
}
