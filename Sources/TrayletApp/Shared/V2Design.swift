import SwiftUI

/// Shared sizes so every window uses the same radii, spacing and control sizes.
/// Radii: `control` for rows and small buttons, `card` for grouped content, `panel` for large text panels.
enum V2Design {
    enum Radius {
        static let control: CGFloat = 8
        static let card: CGFloat = 12
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
    /// Every round icon button in toolbars and text panels.
    static let iconButton: CGFloat = 28
    /// Hairline used around cards; thicker with increased contrast.
    static func stroke(increasedContrast: Bool) -> (opacity: Double, width: CGFloat) { increasedContrast ? (1, 1.5) : (0.5, 0.5) }
}
