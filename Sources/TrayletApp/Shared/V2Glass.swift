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
@MainActor final class V2GlassWindowBacking {
    private weak var window: NSWindow?
    private var content: NSView
    private var observers: Set<AnyCancellable> = []
    init(window: NSWindow, content: NSView) {
        self.window = window; self.content = content
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
        let container = NSView()
        if V2AppearanceState.shared.glassActive {
            window.isOpaque = false; window.backgroundColor = .clear
            if #available(macOS 26, *) {
                let glass = NSGlassEffectView(); glass.cornerRadius = 0; glass.contentView = container
                window.contentView = glass
            } else {
                let effect = NSVisualEffectView(); effect.material = .underWindowBackground
                effect.blendingMode = .behindWindow; effect.state = .active
                container.frame = effect.bounds; container.autoresizingMask = [.width, .height]; effect.addSubview(container)
                window.contentView = effect
            }
        } else {
            window.isOpaque = true; window.backgroundColor = .windowBackgroundColor
            window.contentView = container
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        if let guide = window.contentLayoutGuide as? NSLayoutGuide {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                content.topAnchor.constraint(equalTo: guide.topAnchor),
                content.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
            ])
        } else {
            content.frame = container.bounds
            content.autoresizingMask = [.width, .height]
            content.translatesAutoresizingMaskIntoConstraints = true
        }
    }
}
