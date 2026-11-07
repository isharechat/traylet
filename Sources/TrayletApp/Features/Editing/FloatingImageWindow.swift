import AppKit
import TrayletCore

/// Pure sizing math for floating screenshots, kept separate so it can be unit tested.
enum FloatingImageZoom {
    static let minimumSize = CGSize(width: 80, height: 60)
    static let maximumSize = CGSize(width: 4096, height: 4096)

    static func clampedSize(_ size: CGSize) -> CGSize {
        let width = size.width.isFinite ? size.width : minimumSize.width
        let height = size.height.isFinite ? size.height : minimumSize.height
        return CGSize(width: min(maximumSize.width, max(minimumSize.width, width)),
                      height: min(maximumSize.height, max(minimumSize.height, height)))
    }
}

/// Owns every floating image panel so each stays alive until the user closes it.
@MainActor final class FloatingImageController {
    private var panels: [FloatingImagePanel] = []

    func present(cgImage: CGImage, initialFrame: CGRect) {
        let panel = FloatingImagePanel(cgImage: cgImage, initialFrame: initialFrame)
        panel.onClose = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.panels.removeAll { $0 === panel }
        }
        panels.append(panel)
        panel.orderFrontRegardless()
    }
}

/// A borderless, non-activating panel that floats above every space. It resizes with its window,
/// and the image fills the content area, adapting to the window size.
@MainActor final class FloatingImagePanel: NSPanel, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let cgImage: CGImage
    private let imageView: FloatingImageView

    init(cgImage: CGImage, initialFrame: CGRect) {
        self.cgImage = cgImage
        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        imageView = FloatingImageView(image: NSImage(cgImage: cgImage, size: pixelSize))
        let contentSize = initialFrame.size.width > 0 && initialFrame.size.height > 0 ? initialFrame.size : FloatingImageZoom.minimumSize
        super.init(contentRect: CGRect(origin: .zero, size: contentSize),
                   styleMask: [.borderless, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        acceptsMouseMovedEvents = true
        contentMinSize = FloatingImageZoom.minimumSize
        contentMaxSize = FloatingImageZoom.maximumSize
        contentView = imageView
        delegate = self
        imageView.onCopy = { [weak self] in self?.copyImage() }
        imageView.onSave = { [weak self] in self?.saveImage() }
        imageView.onClose = { [weak self] in self?.close() }
        setFrameOrigin(initialFrame.origin)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private func copyImage() {
        guard let data = pngData() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    private func saveImage() {
        guard let data = pngData() else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = V2L("Traylet.png")
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func pngData() -> Data? {
        NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}

/// Draws the floating image filling the window and drives resizing via scroll wheel, pinch,
/// edge drags and a right-click menu (copy, save, delete, close).
@MainActor final class FloatingImageView: NSView {
    private let image: NSImage
    private let imageRatio: CGFloat
    private var trackingArea: NSTrackingArea?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?

    init(image: NSImage) {
        self.image = image
        self.imageRatio = image.size.width > 0 && image.size.height > 0 ? image.size.width / image.size.height : 1
        super.init(frame: .zero)
        setAccessibilityLabel(V2L("悬浮图片"))
        setAccessibilityHelp(V2L("拖动移动，拖动边缘调整大小，右键更多操作。"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
                                  owner: self, userInfo: nil)
        trackingArea = area
        addTrackingArea(area)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }
        image.draw(in: coverRect(for: bounds.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// The image keeps its aspect ratio and fills the window, cropping the overflow.
    private func coverRect(for size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, image.size.width > 0, image.size.height > 0 else { return .zero }
        let viewRatio = size.width / size.height
        let scale = viewRatio > imageRatio ? size.width / image.size.width : size.height / image.size.height
        let width = image.size.width * scale, height = image.size.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let copy = NSMenuItem(title: V2L("复制"), action: #selector(copyImage), keyEquivalent: "")
        let save = NSMenuItem(title: V2L("保存"), action: #selector(saveImage), keyEquivalent: "")
        let delete = NSMenuItem(title: V2L("删除"), action: #selector(deleteImage), keyEquivalent: "")
        let close = NSMenuItem(title: V2L("关闭"), action: #selector(closeImage), keyEquivalent: "")
        for item in [copy, save, delete, close] { item.target = self; menu.addItem(item) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    /// Shows a resize cursor when the pointer is over an edge the window can drag to resize.
    private func updateCursor(at point: CGPoint) {
        (resizeCursor(at: point) ?? .arrow).set()
    }

    private func resizeCursor(at point: CGPoint) -> NSCursor? {
        let inset: CGFloat = 5
        guard bounds.width > inset * 2, bounds.height > inset * 2 else { return nil }
        let left = point.x < inset
        let right = point.x > bounds.maxX - inset
        let top = point.y < inset
        let bottom = point.y > bounds.maxY - inset
        let position: NSCursor.FrameResizePosition?
        if top && left { position = .topLeft }
        else if top && right { position = .topRight }
        else if bottom && left { position = .bottomLeft }
        else if bottom && right { position = .bottomRight }
        else if left { position = .left }
        else if right { position = .right }
        else if top { position = .top }
        else if bottom { position = .bottom }
        else { position = nil }
        guard let position else { return nil }
        return NSCursor.frameResize(position: position, directions: .all)
    }

    @objc private func copyImage() { onCopy?() }
    @objc private func saveImage() { onSave?() }
    @objc private func deleteImage() { onClose?() }
    @objc private func closeImage() { onClose?() }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        guard delta != 0 else { return }
        resizeWindow(by: CGFloat(pow(1.02, Double(delta))))
    }

    override func magnify(with event: NSEvent) {
        let factor = 1 + event.magnification
        guard factor > 0 else { return }
        resizeWindow(by: factor)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?(); return }
        super.keyDown(with: event)
    }

    private func resizeWindow(by factor: CGFloat) {
        guard factor.isFinite, factor > 0, let window else { return }
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let size = FloatingImageZoom.clampedSize(CGSize(width: window.frame.width * factor, height: window.frame.height * factor))
        var frame = window.frame
        frame.size = size
        frame.origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        window.setFrame(frame, display: true, animate: false)
    }
}
