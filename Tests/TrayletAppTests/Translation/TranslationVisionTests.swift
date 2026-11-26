import Foundation
import Testing
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import TrayletCore
@testable import TrayletApp

@Suite("Translation Vision")
struct TranslationVisionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAYLET_REWRITE_VISION_TEST"] == "1", "Synthetic Vision requires an environment that allows CoreVideo; no screen pixels are used."))
    func recognizesSyntheticPrintedEnglish() async throws {
        let context = try #require(CGContext(data: nil, width: 700, height: 120, bitsPerComponent: 8, bytesPerRow: 2800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 700, height: 120))
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.textPosition = CGPoint(x: 20, y: 45)
        let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
        let string = NSAttributedString(string: "HELLO TRAYLET", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
        let cgImage = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))
        let image = try RasterImage(pngData: data as Data)
        let result = try await TranslationVisionOCR().recognize(image)
        #expect(result.contains("HELLO TRAYLET"))
    }
}
