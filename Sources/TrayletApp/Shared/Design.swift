import SwiftUI

/// Shared sizes so every window uses the same radii, spacing and control sizes.
/// Radii: `control` for rows and small buttons, `card` for grouped content, `panel` for large text panels.
enum Design {
    enum Radius {
        static let badge: CGFloat = 6
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let floating: CGFloat = 16
        static let window: CGFloat = 16
        static let panel: CGFloat = 18
    }
    /// Spacing steps (multiples of 4): xs 4, s 8, m 12, l 16, xl 24.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }
    /// macOS 27 window chrome & split-view metrics.
    enum Layout {
        static let toolbarHeight: CGFloat = 44
        static let compactTitlebarHeight: CGFloat = 38
        static let capsuleHeight: CGFloat = 32
        static let trafficLightsClearance: CGFloat = 78
        static let settingsSidebarWidth: CGFloat = 224
        static let clipboardSidebarWidth: CGFloat = 300
        static let ocrSidebarWidth: CGFloat = 300
    }
    /// Low-contrast harmonious neutral surfaces used when Liquid Glass is turned off or reduced transparency is active.
    enum SolidSurface {
        static func content(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 0.118, green: 0.118, blue: 0.125)
                : Color(red: 0.969, green: 0.969, blue: 0.973)
        }
        static func sidebar(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 0.145, green: 0.145, blue: 0.157)
                : Color(red: 0.937, green: 0.937, blue: 0.945)
        }
        static func toolbar(for scheme: ColorScheme) -> Color {
            content(for: scheme)
        }
        static func capsuleFill(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 0.173, green: 0.173, blue: 0.188)
                : Color.white
        }
        static func capsuleStroke(for scheme: ColorScheme, highContrast: Bool) -> Color {
            if highContrast { return Color(nsColor: .separatorColor) }
            return scheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.09)
        }
        static func bandTint(for scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.025)
        }
        static var windowNSColor: NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                    ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.125, alpha: 1)
                    : NSColor(srgbRed: 0.969, green: 0.969, blue: 0.973, alpha: 1)
            }
        }
    }
    enum Animation {
        static let snappy = SwiftUI.Animation.snappy(duration: 0.2)
    }
    /// Every round icon button in toolbars and text panels.
    static let iconButton: CGFloat = 28
    /// Hairline used around cards; thicker with increased contrast.
    static func stroke(increasedContrast: Bool) -> (opacity: Double, width: CGFloat) { increasedContrast ? (1, 1.5) : (0.5, 0.5) }
}
