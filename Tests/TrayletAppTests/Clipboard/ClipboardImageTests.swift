import AppKit
import Testing
@testable import TrayletApp

@Suite("Clipboard Image Policy") @MainActor struct ClipboardImageTests {
    private func image(width: Int, height: Int, type: NSBitmapImageRep.FileType) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        if let bytes = rep.bitmapData { memset(bytes, 127, rep.bytesPerRow * height) }
        return try #require(rep.representation(using: type, properties: [:]))
    }
    @Test func supportsRealPNGJPEGAndTIFFAndRejectsMismatchedFormats() throws {
        let pairs: [(NSBitmapImageRep.FileType, String)] = [(.png, "public.png"), (.jpeg, "public.jpeg"), (.tiff, "public.tiff")]
        for (format, type) in pairs {
            let data = try image(width: 8, height: 7, type: format)
            #expect(ClipboardPolicy.valid([.init(representations: [type: data])]))
            let wrong = type == "public.png" ? "public.jpeg" : "public.png"
            #expect(!ClipboardPolicy.valid([.init(representations: [wrong: data])]))
        }
    }
    @Test func pixelLimitRejectsSmallCompressedOversizedImage() throws {
        let data = try image(width: 4001, height: 4000, type: .png)
        #expect(data.count < ClipboardPolicy.itemBytes)
        #expect(!ClipboardPolicy.valid([.init(representations: ["public.png": data])]))
    }
}
