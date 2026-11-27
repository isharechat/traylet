import AppKit
import SwiftUI

/// The simplified, rounded icy-white shamrock (☘️) on the selected azure-blue tile. Full-color artwork is shared
/// by every brand surface; the menu bar uses its complete silhouette so macOS can supply the correct contrast.
@MainActor enum Brand {
    static let iconURL = Bundle.module.url(forResource: "TrayletAppIcon", withExtension: "png")!
    static let icon = NSImage(contentsOf: iconURL)!

    static func markPaths(in rect: NSRect) -> [NSBezierPath] {
        let s = min(rect.width, rect.height) / 100.0
        let ox = rect.minX + (rect.width - 100.0 * s) / 2.0
        let oy = rect.minY + (rect.height - 100.0 * s) / 2.0
        let cx: CGFloat = 48.0
        let cy: CGFloat = 46.0

        func rot(_ lx: CGFloat, _ ly: CGFloat, angleDeg: CGFloat) -> NSPoint {
            let rad = angleDeg * .pi / 180.0
            let cosA = cos(rad)
            let sinA = sin(rad)
            let x = cx + lx * cosA - ly * sinA
            let y = cy + lx * sinA + ly * cosA
            return NSPoint(x: ox + x * s, y: oy + y * s)
        }

        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: ox + x * s, y: oy + y * s)
        }

        var paths: [NSBezierPath] = []

        // Three symmetrical plump, rounded shamrock leaves (top, bottom-right, bottom-left)
        // All subpaths are wound clockwise in flipped coordinates so .nonZero fills solidly.
        for angle in [CGFloat(0), CGFloat(120), CGFloat(-120)] {
            let leaf = NSBezierPath()
            leaf.move(to: rot(0, 4, angleDeg: angle))
            leaf.curve(
                to: rot(-19.5, -23.5, angleDeg: angle),
                controlPoint1: rot(-7, -7, angleDeg: angle),
                controlPoint2: rot(-22, -13, angleDeg: angle)
            )
            leaf.curve(
                to: rot(-3.5, -29.5, angleDeg: angle),
                controlPoint1: rot(-18, -32, angleDeg: angle),
                controlPoint2: rot(-9.5, -35, angleDeg: angle)
            )
            leaf.curve(
                to: rot(3.5, -29.5, angleDeg: angle),
                controlPoint1: rot(-1, -26.5, angleDeg: angle),
                controlPoint2: rot(1, -26.5, angleDeg: angle)
            )
            leaf.curve(
                to: rot(19.5, -23.5, angleDeg: angle),
                controlPoint1: rot(9.5, -35, angleDeg: angle),
                controlPoint2: rot(18, -32, angleDeg: angle)
            )
            leaf.curve(
                to: rot(0, 4, angleDeg: angle),
                controlPoint1: rot(22, -13, angleDeg: angle),
                controlPoint2: rot(7, -7, angleDeg: angle)
            )
            leaf.close()
            paths.append(leaf)
        }

        // Gentle curved stem with rounded tip (wound clockwise in flipped coordinates)
        let stem = NSBezierPath()
        stem.move(to: pt(44.2, 46))
        stem.line(to: pt(51.8, 46))
        stem.curve(to: pt(58.6, 82.8), controlPoint1: pt(51.8, 61), controlPoint2: pt(54.0, 72.5))
        stem.curve(to: pt(51.2, 84.4), controlPoint1: pt(57.8, 87.2), controlPoint2: pt(53.0, 87.8))
        stem.curve(to: pt(44.2, 46), controlPoint1: pt(46.2, 73.5), controlPoint2: pt(44.2, 62))
        stem.close()
        paths.append(stem)

        return paths
    }

    static func mark(size: CGFloat = 18, template: Bool = true) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let combined = NSBezierPath()
            for p in markPaths(in: rect) {
                combined.append(p)
            }
            combined.windingRule = .nonZero
            if template {
                NSColor.black.setFill()
                combined.fill()
            } else {
                NSGradient(starting: .white, ending: NSColor(srgbRed: 0.75, green: 0.93, blue: 1.0, alpha: 1))!
                    .draw(in: combined, angle: 90)
            }
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "Traylet"
        return image
    }
}

struct BrandIcon: View {
    var size: CGFloat = 40
    var body: some View {
        Image(nsImage: Brand.icon).resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}
