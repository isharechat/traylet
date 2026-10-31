import AppKit
import Testing
@testable import TrayletApp

@MainActor struct BrandTests {
    @Test func fullColorArtworkLoadsFromPackagedResource() throws {
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: V2Brand.iconURL)))
        #expect(bitmap.pixelsWide == 1024 && bitmap.pixelsHigh == 1024)
        #expect(bitmap.hasAlpha)
        #expect(!V2Brand.icon.isTemplate)
    }

    @Test func menuSilhouetteHasTransparentMarginAndVisibleContentAtBothScales() throws {
        for size: CGFloat in [18, 36] {
            let image = V2Brand.mark(size: size)
            #expect(image.isTemplate && image.size == NSSize(width: size, height: size))
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            var filled = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try #require(bitmap.colorAt(x: x, y: y))
                    if color.alphaComponent > 0.5 { filled += 1 }
                }
            }
            // Reject empty/near-empty rasterization without prescribing the old bold mark's weight.
            // The complete reference has narrower strokes and large open folded terminals.
            #expect(filled > bitmap.pixelsWide * bitmap.pixelsHigh / 8)
            #expect(filled < bitmap.pixelsWide * bitmap.pixelsHigh * 3 / 4)
            let corner = try #require(bitmap.colorAt(x: 0, y: 0))
            #expect(corner.alphaComponent == 0)
        }
        if let path = ProcessInfo.processInfo.environment["TRAYLET_BRAND_EXPORT_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, size, template) in [("traylet-logo.png", CGFloat(1024), false), ("traylet-menubar-template.png", CGFloat(36), true)] {
                let data = try #require(V2Brand.mark(size: size, template: template).tiffRepresentation)
                let bitmap = try #require(NSBitmapImageRep(data: data))
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
