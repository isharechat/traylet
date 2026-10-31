import AppKit
import SwiftUI

/// The complete icy-white T on the selected azure-blue tile. Full-color artwork is shared by every brand surface;
/// the menu bar uses its complete silhouette so macOS can supply the correct contrast.
@MainActor enum V2Brand {
    static let iconURL = Bundle.module.url(forResource: "TrayletAppIcon", withExtension: "png")!
    static let icon = NSImage(contentsOf: iconURL)!

    static func mark(size: CGFloat = 18, template: Bool = true) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let scale = rect.width / 390
            let placement = AffineTransform(m11: scale, m12: 0, m21: 0, m22: scale,
                                            tX: -70 * scale, tY: -60 * scale)
            let pieces: [[NSPoint]] = [
                [.init(x: 95, y: 70), .init(x: 137, y: 70), .init(x: 182, y: 118), .init(x: 254, y: 118), .init(x: 254, y: 291), .init(x: 231, y: 311), .init(x: 231, y: 143), .init(x: 177, y: 143), .init(x: 126, y: 94), .init(x: 137, y: 126), .init(x: 145, y: 119), .init(x: 157, y: 140), .init(x: 143, y: 153), .init(x: 114, y: 153)],
                [.init(x: 174, y: 91), .init(x: 187, y: 78), .init(x: 344, y: 78), .init(x: 399, y: 128), .init(x: 412, y: 94), .init(x: 394, y: 111), .init(x: 371, y: 89), .init(x: 394, y: 70), .init(x: 435, y: 70), .init(x: 413, y: 149), .init(x: 387, y: 153), .init(x: 335, y: 103), .init(x: 188, y: 103)],
                [.init(x: 272, y: 119), .init(x: 337, y: 119), .init(x: 356, y: 142), .init(x: 296, y: 142), .init(x: 296, y: 294), .init(x: 247, y: 343), .init(x: 247, y: 356), .init(x: 280, y: 387), .init(x: 280, y: 356), .init(x: 267, y: 343), .init(x: 279, y: 329), .init(x: 305, y: 353), .init(x: 305, y: 427), .init(x: 299, y: 435), .init(x: 223, y: 365), .init(x: 222, y: 340), .init(x: 272, y: 290)]
            ]
            for points in pieces {
                let path = NSBezierPath()
                path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }; path.close()
                path.transform(using: placement)
                if template { NSColor.black.setFill(); path.fill() }
                else {
                    NSGradient(starting: .white, ending: NSColor(srgbRed: 0.75, green: 0.93, blue: 1.0, alpha: 1))!
                        .draw(in: path, angle: 90)
                }
            }
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "Traylet"
        return image
    }
}

struct V2BrandIcon: View {
    var size: CGFloat = 40
    var body: some View {
        Image(nsImage: V2Brand.icon).resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}
