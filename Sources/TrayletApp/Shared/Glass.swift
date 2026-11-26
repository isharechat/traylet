import AppKit
import Combine
import SwiftUI

/// Shared switch for the Liquid Glass look. Glass is the default; the user can turn it off, and reduced
/// transparency or increased contrast always fall back to solid surfaces.
@MainActor final class AppearanceState: ObservableObject {
    static let shared = AppearanceState()
    @Published var glassEnabled = true
    /// True when windows should draw on system glass right now.
    var glassActive: Bool {
        glassEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
}

/// Liquid Glass on macOS 26+, a system material on macOS 15, and a solid surface when glass is off or the
/// accessibility settings ask for it.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var interactive = false
    var elevated = false
    @ObservedObject private var state = AppearanceState.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder func body(content: Content) -> some View {
        if state.glassEnabled && !reduceTransparency && contrast != .increased {
            if #available(macOS 26, *) {
                if interactive {
                    content.glassEffect(.regular.interactive(), in: shape)
                } else {
                    content.glassEffect(.regular, in: shape)
                }
            } else {
                content
                    .background(.regularMaterial, in: shape)
                    .overlay(shape.strokeBorder(specularStroke, lineWidth: 0.75))
                    .shadow(color: elevated ? .black.opacity(colorScheme == .dark ? 0.36 : 0.14) : .clear,
                            radius: elevated ? 10 : 0, y: elevated ? 4 : 0)
            }
        } else {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: contrast == .increased ? 2 : 1))
        }
    }
    private var specularStroke: LinearGradient {
        let top = Color.white.opacity(colorScheme == .dark ? 0.24 : 0.72)
        let bottom = Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.45 : 0.35)
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}

extension View {
    func v2Glass<S: InsettableShape>(in shape: S, interactive: Bool = false, elevated: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive, elevated: elevated))
    }
    /// Glass drawn behind the view instead of around it, so the content (text, buttons, icons) is never part of the glass layer.
    func v2GlassBackground<S: InsettableShape>(in shape: S, interactive: Bool = false, elevated: Bool = false) -> some View {
        background { Color.clear.v2Glass(in: shape, interactive: interactive, elevated: elevated) }
    }
}

/// Compact macOS-style capsule badge for status, metadata, and engine tags.
struct StatusPill: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = .secondary
    var prominent: Bool = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(
            tint.opacity(prominent ? 0.16 : 0.11),
            in: Capsule()
        )
        .overlay {
            if contrast == .increased {
                Capsule().strokeBorder(tint.opacity(0.65), lineWidth: 1)
            }
        }
    }
}

/// Puts a window's SwiftUI content on system glass (or a solid window background) and follows the setting live.
/// `cornerRadius` rounds the surface for borderless panels; 0 keeps the native full-window look.
@MainActor final class GlassWindowBacking {
    private weak var window: NSWindow?
    private var content: NSView
    private let cornerRadius: CGFloat
    private var observers: Set<AnyCancellable> = []
    init(window: NSWindow, content: NSView, cornerRadius: CGFloat = 0) {
        self.window = window; self.content = content; self.cornerRadius = cornerRadius
        apply()
        AppearanceState.shared.$glassEnabled.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply() } }
        }.store(in: &observers)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in MainActor.assumeIsolated { self?.apply() } }.store(in: &observers)
    }
    func replaceContent(_ view: NSView) { content.removeFromSuperview(); content = view; apply() }
    func apply() {
        guard let window else { return }
        content.removeFromSuperview()
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.titlebarAppearsTransparent = true
        let contentContainer: NSView
        if AppearanceState.shared.glassActive {
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
            let solid = RoundedSolidView(cornerRadius: cornerRadius)
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
private final class RoundedSolidView: NSView {
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
