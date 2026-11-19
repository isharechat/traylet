import AppKit
import Combine
import SwiftUI

/// Shared switch for the Liquid Glass look. Glass is the default; the user can turn it off, and reduced
/// transparency or increased contrast always fall back to solid surfaces.
@MainActor final class V2AppearanceState: ObservableObject {
    static let shared = V2AppearanceState()
    @Published var glassEnabled = true
    /// True when windows should draw on system glass right now.
    var glassActive: Bool {
        glassEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
}

/// Liquid Glass on macOS 26+, a system material on macOS 15, and a solid surface when glass is off or the
/// accessibility settings ask for it.
struct V2GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    @ObservedObject private var state = V2AppearanceState.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder func body(content: Content) -> some View {
        if state.glassEnabled && !reduceTransparency && contrast != .increased {
            if #available(macOS 26, *) { content.glassEffect(.regular, in: shape) }
            else {
                content.background(.regularMaterial, in: shape)
                    .overlay(shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
            }
        } else {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: contrast == .increased ? 2 : 1))
        }
    }
}

extension View {
    func v2Glass<S: InsettableShape>(in shape: S) -> some View { modifier(V2GlassSurface(shape: shape)) }
    /// Glass drawn behind the view instead of around it, so the content (text, buttons, icons) is never part of the glass layer.
    func v2GlassBackground<S: InsettableShape>(in shape: S) -> some View { background { Color.clear.v2Glass(in: shape) } }
}

/// Puts a window's SwiftUI content on system glass (or a solid window background) and follows the setting live.
/// `cornerRadius` rounds the surface for borderless panels; 0 keeps the native full-window look.
@MainActor final class V2GlassWindowBacking {
    private weak var window: NSWindow?
    private var content: NSView
    private let cornerRadius: CGFloat
    private var observers: Set<AnyCancellable> = []
    init(window: NSWindow, content: NSView, cornerRadius: CGFloat = 0) {
        self.window = window; self.content = content; self.cornerRadius = cornerRadius
        apply()
        V2AppearanceState.shared.$glassEnabled.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply() } }
        }.store(in: &observers)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in MainActor.assumeIsolated { self?.apply() } }.store(in: &observers)
    }
    func replaceContent(_ view: NSView) { content.removeFromSuperview(); content = view; apply() }
    func apply() {
        guard let window else { return }
        content.removeFromSuperview()
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        let contentContainer: NSView
        if V2AppearanceState.shared.glassActive {
            window.isOpaque = false; window.backgroundColor = .clear
            let container = NSView()
            contentContainer = container
            if #available(macOS 26, *) {
                let glass = NSGlassEffectView(); glass.cornerRadius = cornerRadius; glass.contentView = container
                window.contentView = glass
            } else {
                let effect = NSVisualEffectView(); effect.material = .underWindowBackground
                effect.blendingMode = .behindWindow; effect.state = .active
                window.contentView = effect
                if cornerRadius > 0 { effect.maskImage = Self.roundedMask(size: Self.contentSize(of: window), radius: cornerRadius) }
                container.frame = effect.bounds; container.autoresizingMask = [.width, .height]; effect.addSubview(container)
            }
        } else if cornerRadius > 0 {
            window.isOpaque = false; window.backgroundColor = .clear
            let solid = V2RoundedSolidView(cornerRadius: cornerRadius)
            contentContainer = solid
            window.contentView = solid
        } else {
            window.isOpaque = true; window.backgroundColor = .windowBackgroundColor
            let container = NSView()
            contentContainer = container
            window.contentView = container
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(content)
        if let guide = window.contentLayoutGuide as? NSLayoutGuide {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                content.topAnchor.constraint(equalTo: guide.topAnchor),
                content.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
            ])
        } else {
            content.frame = contentContainer.bounds
            content.autoresizingMask = [.width, .height]
            content.translatesAutoresizingMaskIntoConstraints = true
        }
    }
    private static func contentSize(of window: NSWindow) -> CGSize {
        window.contentRect(forFrameRect: window.frame).size
    }
    private static func roundedMask(size: CGSize, radius: CGFloat) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: radius, yRadius: radius).fill()
        image.unlockFocus()
        return image
    }
}

/// A transparent container that paints a rounded solid window background when glass is off.
private final class V2RoundedSolidView: NSView {
    let cornerRadius: CGFloat
    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
