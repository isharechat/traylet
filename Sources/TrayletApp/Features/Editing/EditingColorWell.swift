import AppKit
import SwiftUI

/// AppKit resets the shared panel's level during activation; configure it afterwards.
@MainActor final class EditingColorPanel {
    private weak var activeWell: EditingNativeColorWell?
    var isManagingColorWell: Bool { activeWell != nil }
    private struct State {
        let level: NSWindow.Level
        let behavior: NSWindow.CollectionBehavior
        let hidesOnDeactivate: Bool
        let showsAlpha: Bool
        let wasVisible: Bool
        let accessoryView: NSView?
    }
    private var state: State?

    func prepare(_ well: EditingNativeColorWell) {
        if activeWell !== well { close() }
        guard state == nil else { return }
        let panel = NSColorPanel.shared
        state = State(level:panel.level,behavior:panel.collectionBehavior,hidesOnDeactivate:panel.hidesOnDeactivate,showsAlpha:panel.showsAlpha,wasVisible:panel.isVisible,accessoryView:panel.accessoryView)
        activeWell = well
        panel.accessoryView = EditingColorPaletteView()
    }

    func didActivate(_ well: EditingNativeColorWell) {
        guard activeWell === well, let window = well.window else { close(); return }
        let panel = NSColorPanel.shared
        panel.level = NSWindow.Level(rawValue:window.level.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.showsAlpha = false
        // Keep the picker on the capture's display, including screens with negative coordinates.
        if let screen = window.screen {
            var frame = panel.frame
            let visible = screen.visibleFrame
            frame.origin.x = max(visible.minX,min(frame.minX,visible.maxX-frame.width))
            frame.origin.y = max(visible.minY,min(frame.minY,visible.maxY-frame.height))
            panel.setFrameOrigin(frame.origin)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func didDeactivate(_ well: EditingNativeColorWell) {
        if activeWell === well { restore() }
    }

    func close() {
        let well = activeWell
        restore()
        well?.deactivate()
    }

    private func restore() {
        guard let state else { return }
        self.state = nil; activeWell = nil
        let panel = NSColorPanel.shared
        if !state.wasVisible { panel.orderOut(nil) }
        panel.level = state.level
        panel.collectionBehavior = state.behavior
        panel.hidesOnDeactivate = state.hidesOnDeactivate
        panel.showsAlpha = state.showsAlpha
        panel.accessoryView = state.accessoryView
    }
}

/// Shortcuts live inside the system picker and never occupy the annotation toolbar.
@MainActor final class EditingColorPaletteView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
        let colors: [(String, NSColor)] = [("红色", .systemRed), ("橙色", .systemOrange),
            ("黄色", .systemYellow), ("绿色", .systemGreen), ("蓝色", .systemBlue),
            ("紫色", .systemPurple), ("黑色", .black), ("白色", .white)]
        let stack = NSStackView(views: colors.map { EditingPaletteButton(name: $0.0, color: $0.1) })
        stack.orientation = .horizontal; stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor final class EditingPaletteButton: NSButton {
    let paletteColor: NSColor
    init(name: String, color: NSColor) {
        paletteColor = color
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 28))
        title = ""; isBordered = false; bezelStyle = .regularSquare
        image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            let path = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 18, height: 18))
            color.setFill(); path.fill(); NSColor.gray.setStroke(); path.lineWidth = 0.5; path.stroke()
            return true
        }
        toolTip = V2L(name); setAccessibilityLabel(V2L(name))
        target = self; action = #selector(selectColor)
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func selectColor() { NSColorPanel.shared.color = paletteColor }
}

@MainActor final class EditingNativeColorWell: NSColorWell {
    let panel: EditingColorPanel
    var onChange: ((NSColor) -> Void)?
    struct Interaction {
        var change: (NSColor) -> Void
        var finish: (Bool) -> Void
        var isValid: () -> Bool
    }
    var makeColorInteraction: (() -> Interaction?)?
    private var colorInteraction: Interaction?

    init(panel: EditingColorPanel) {
        self.panel = panel
        super.init(frame:NSRect(x:0,y:0,width:44,height:24))
        colorWellStyle = .default
        target = self; action = #selector(colorChanged)
        isContinuous = true
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Gesture entry points are also usable with hidden native controls, without showing the system panel.
    func beginColorEditing() {
        if colorInteraction?.isValid() == true { return }
        endColorEditing(commit:false); colorInteraction = makeColorInteraction?()
    }
    func previewColor(_ value:NSColor) {
        if let interaction = colorInteraction {
            if interaction.isValid() { interaction.change(value) }
        } else { onChange?(value) }
    }
    func endColorEditing(commit:Bool = true) {
        let interaction = colorInteraction; colorInteraction = nil; interaction?.finish(commit)
    }
    func discardInvalidColorInteraction() {
        guard let interaction = colorInteraction, !interaction.isValid() else { return }
        endColorEditing(commit:false)
        if isActive { deactivate() }
    }

    override func activate(_ exclusive: Bool) {
        guard window != nil else { return }
        beginColorEditing(); panel.prepare(self)
        super.activate(exclusive)
        panel.didActivate(self)
    }
    override func deactivate() {
        super.deactivate()
        endColorEditing(); panel.didDeactivate(self)
    }
    override func viewWillMove(toWindow newWindow:NSWindow?) {
        if newWindow == nil { endColorEditing(commit:false); deactivate() }
        super.viewWillMove(toWindow:newWindow)
    }
    @objc private func colorChanged() {
        // System panel callbacks belong to its activation, never to a replacement target's current binding.
        guard colorInteraction != nil else { return }; previewColor(color)
    }
}

struct EditingColorWell: NSViewRepresentable {
    @ObservedObject var session: EditingSession
    let panel: EditingColorPanel

    func makeNSView(context:Context) -> EditingNativeColorWell {
        let well = EditingNativeColorWell(panel:panel)
        updateNSView(well,context:context)
        return well
    }
    func updateNSView(_ well:EditingNativeColorWell,context:Context) {
        well.discardInvalidColorInteraction()
        if !well.color.isEqual(session.effectiveStyle.color) { well.color = session.effectiveStyle.color }
        let styleContext = session.captureStyleContext()
        well.onChange = { [weak session] color in
            guard let session else { return }
            var style = session.effectiveStyle; style.color = color
            _ = session.setEffectiveStyle(style,context:styleContext)
        }
        well.makeColorInteraction = { [weak session] in
            guard let session, let token = session.beginStyleEditing(context:styleContext) else { return nil }
            return EditingNativeColorWell.Interaction(change:{ [weak session] color in
                guard let session else { return }
                var style = session.effectiveStyle; style.color = color
                _ = session.updateStyle(style,token:token)
            },finish:{ [weak session] commit in
                if commit { session?.finishStyleEditing(token) } else { session?.cancelStyleEditing(token) }
            },isValid:{ [weak session] in session?.isStyleEditing(token) == true })
        }
        well.toolTip = V2L("自定颜色")
        well.setAccessibilityLabel(V2L("自定颜色"))
    }
    static func dismantleNSView(_ well:EditingNativeColorWell,coordinator:()) {
        well.endColorEditing(commit:false); well.deactivate(); well.onChange = nil; well.makeColorInteraction = nil
    }
}
