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
            content.background(Design.SolidSurface.capsuleFill(for: colorScheme), in: shape)
                .overlay(
                    shape.strokeBorder(
                        Design.SolidSurface.capsuleStroke(for: colorScheme, highContrast: contrast == .increased),
                        lineWidth: contrast == .increased ? 2 : 0.75
                    )
                )
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.04), radius: 2, y: 0.5)
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

/// 36pt macOS 27 Liquid Glass capsule container for toolbar control groups and search bars.
struct Mac27GlassCapsule<Content: View>: View {
    var spacing: CGFloat = 4
    var horizontalPadding: CGFloat = 4
    var height: CGFloat = Design.Layout.capsuleHeight
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: spacing, content: content)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .v2GlassBackground(in: Capsule(), interactive: true)
    }
}

/// 36pt macOS 27 circular interactive Liquid Glass button.
struct Mac27GlassCircleButton: View {
    let symbol: String
    let label: String
    var help: String? = nil
    var active = false
    var tint: Color? = nil
    var iconSize: CGFloat = 13.5
    var disabled = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: active ? .semibold : .regular))
                .foregroundStyle(tint ?? (active ? Color.accentColor : Color.primary))
                .frame(width: Design.Layout.capsuleHeight, height: Design.Layout.capsuleHeight)
                .background(
                    active ? Color.accentColor.opacity(hovering ? 0.22 : 0.16)
                           : (hovering && !disabled ? Color.primary.opacity(0.06) : Color.clear),
                    in: Circle()
                )
                .overlay {
                    if active && contrast == .increased {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovering = $0 }
        .help(L(help ?? label))
        .accessibilityLabel(L(label))
    }
}

/// Integrated unified toolbar with subtle translucent edge and bottom hairline.
struct Mac27ToolbarBar<Content: View>: View {
    var leadingPadding: CGFloat = 16
    var trailingPadding: CGFloat = 14
    @ObservedObject private var appearance = AppearanceState.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: () -> Content

    private var usesGlass: Bool { appearance.glassActive && !reduceTransparency && contrast != .increased }

    var body: some View {
        HStack(spacing: 8, content: content)
            .padding(.leading, leadingPadding)
            .padding(.trailing, trailingPadding)
            .frame(height: Design.Layout.toolbarHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if usesGlass {
                    Rectangle().fill(.bar)
                } else {
                    Rectangle().fill(Design.SolidSurface.toolbar(for: colorScheme))
                }
            }
            .overlay(alignment: .bottom) {
                Divider()
            }
    }
}

/// Full-height translucent macOS 27 sidebar surface (transparent over window glass, harmonious soft neutral plane in solid mode).
struct Mac27SidebarSurface: ViewModifier {
    @ObservedObject private var appearance = AppearanceState.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    private var usesGlass: Bool { appearance.glassActive && !reduceTransparency && contrast != .increased }

    func body(content: Content) -> some View {
        content.background {
            if !usesGlass {
                Design.SolidSurface.sidebar(for: colorScheme)
            }
        }
    }
}

/// Clean readable primary content surface for right/main window panes (no glass-on-glass nesting).
struct Mac27ContentSurface: ViewModifier {
    @ObservedObject private var appearance = AppearanceState.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    private var usesGlass: Bool { appearance.glassActive && !reduceTransparency && contrast != .increased }

    func body(content: Content) -> some View {
        content.background {
            if usesGlass {
                Color(nsColor: .textBackgroundColor)
            } else {
                Design.SolidSurface.content(for: colorScheme)
            }
        }
    }
}

/// 32pt macOS 27 capsule segmented control with 24pt inner pills and subtle separators.
struct Mac27SegmentedControl<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Mac27GlassCapsule(spacing: 2, horizontalPadding: 4) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                let selected = selection == option
                if index > 0 {
                    let prevSelected = selection == options[index - 1]
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(selected || prevSelected ? 0 : 0.65))
                        .frame(width: 1, height: 14)
                }
                Button {
                    if reduceMotion {
                        selection = option
                    } else {
                        withAnimation(Design.Animation.snappy) { selection = option }
                    }
                } label: {
                    Text(title(option))
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(
                            selected ? Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.09) : Color.clear,
                            in: Capsule()
                        )
                        .overlay {
                            if selected && contrast == .increased {
                                Capsule().strokeBorder(Color.primary.opacity(0.65), lineWidth: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .fixedSize()
    }
}

extension View {
    func mac27SidebarSurface() -> some View { modifier(Mac27SidebarSurface()) }
    func mac27ContentSurface() -> some View { modifier(Mac27ContentSurface()) }
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

/// 28pt circular workspace icon button with hover highlight and consistent accessibility labels.
struct WorkspaceIconButton: View {
    let symbol: String
    let label: String
    var help: String? = nil
    var tint: Color? = nil
    var size: CGFloat = Design.iconButton
    var iconSize: CGFloat = 13
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(tint ?? Color.primary)
                .frame(width: size, height: size)
                .background(hovering && !disabled ? Color.primary.opacity(0.08) : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovering = $0 }
        .help(L(help ?? label))
        .accessibilityLabel(L(label))
    }
}

/// Copy button that briefly confirms with a green checkmark after copying.
struct CopyIconButton: View {
    let label: String
    var size: CGFloat = Design.iconButton
    var iconSize: CGFloat = 13
    var disabled = false
    let action: () -> Void
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        WorkspaceIconButton(
            symbol: copied ? "checkmark" : "doc.on.doc",
            label: label,
            tint: copied ? .green : nil,
            size: size,
            iconSize: iconSize,
            disabled: disabled
        ) {
            action()
            resetTask?.cancel()
            withAnimation(Design.Animation.snappy) { copied = true }
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled else { return }
                withAnimation(Design.Animation.snappy) { copied = false }
            }
        }
        .onDisappear { resetTask?.cancel() }
    }
}

extension View {
    /// Unified focus border and subtle glow for workspace text panels.
    func v2PanelFocusRing(focused: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: Design.Radius.panel)
                .strokeBorder(Color.accentColor.opacity(focused ? 0.85 : 0), lineWidth: focused ? 1.5 : 0)
                .allowsHitTesting(false)
        )
        .shadow(color: focused ? Color.accentColor.opacity(0.14) : .clear, radius: 5)
    }
}

/// Puts a window's SwiftUI content on system glass (or a solid window background) and follows the setting live.
/// `cornerRadius` rounds the surface for borderless panels; 0 keeps the native full-window look.
@MainActor final class GlassWindowBacking {
    static func hostingView<Content: View>(_ rootView: Content, fullBleed: Bool = true) -> NSHostingView<Content> {
        let hosting = NSHostingView(rootView: rootView)
        if fullBleed {
            hosting.safeAreaRegions = []
        }
        return hosting
    }

    private weak var window: NSWindow?
    private var content: NSView
    private let cornerRadius: CGFloat
    private let fullBleedTitlebar: Bool
    private var observers: Set<AnyCancellable> = []
    init(window: NSWindow, content: NSView, cornerRadius: CGFloat = 0, fullBleedTitlebar: Bool = false) {
        self.window = window; self.content = content; self.cornerRadius = cornerRadius; self.fullBleedTitlebar = fullBleedTitlebar
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
        if fullBleedTitlebar {
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
        }
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
            window.isOpaque = true; window.backgroundColor = Design.SolidSurface.windowNSColor
            let container = NSView()
            contentContainer = container
            window.contentView = container
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(content)
        if !fullBleedTitlebar, let guide = window.contentLayoutGuide as? NSLayoutGuide {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                content.topAnchor.constraint(equalTo: guide.topAnchor),
                content.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                content.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                content.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
            ])
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
        Design.SolidSurface.windowNSColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
