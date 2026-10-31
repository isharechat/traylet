import AppKit
import Testing
import TrayletCore
@testable import TrayletApp

/// Timing probes for hot paths; run with TRAYLET_PERF=1 to print numbers. They never gate normal runs.
@Suite("Performance Probes") @MainActor struct PerformanceProbes {

    static func screenshot(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for i in 0..<40 {
            context.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1))
            context.fill(CGRect(x: i * width / 40, y: 0, width: width / 40, height: height))
        }
        // A vertical ramp, so any row offset shows up as a different shade.
        for y in 0..<height {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.8 * CGFloat(y) / CGFloat(height)))
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        return context.makeImage()!
    }
    static func time(_ label: String, repeats: Int = 3, _ body: () throws -> Void) rethrows {
        var best = Double.infinity
        for _ in 0..<repeats {
            let start = ContinuousClock.now
            try body()
            let elapsed = ContinuousClock.now - start
            best = min(best, Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        print("PERF \(label): \(String(format: "%.1f", best)) ms")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAYLET_PERF"] != nil)) func blurComposeOnRetinaScreenshot() throws {
        let image = Self.screenshot(width: 3024, height: 1964)
        var document = EditingDocument(canvas: CGSize(width: 1512, height: 982), fullScreen: true)
        for i in 0..<8 {
            let y = CGFloat(100 + i * 100)
            document.append(EditingMark(tool: .blur, points: [CGPoint(x: 200, y: y), CGPoint(x: 420, y: y)], style: EditingStyle(brushSize: 40)))
        }
        try Self.time("compose 3024x1964 with 8 blur strokes") { _ = try EditingRenderer.compose(image, document: document) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAYLET_PERF"] != nil)) func clipboardRowDisplay() {
        let entries = (0..<300).map { i in
            let text = String(repeating: "第\(i)条剪贴板内容 with some English words. ", count: 400)
            return ClipboardEntry(id: UUID(), digest: "\(i)", items: [.text(text)], capturedAt: Date(), favorite: false, application: "com.example")
        }
        let controller = ClipboardController(source: ProbeSource(), writer: ProbeWriter())
        Self.time("300 rows display text x10 renders") {
            for _ in 0..<10 { for entry in entries { _ = controller.display(entry) } }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAYLET_PERF"] != nil)) func translationTypingIntoLongText() {
        let flow = TranslationFlow()
        flow.input = String(repeating: "The weather is lovely today, so let us walk in the park. ", count: 300)
        Self.time("200 keystrokes appended to 17k chars") {
            for i in 0..<200 { flow.input += i % 2 == 0 ? "a" : " " }
        }
    }
}

@MainActor private final class ProbeSource: ClipboardSource {
    var generation = 0
    func read(expectedGeneration: Int, excluding: Set<String>) -> V2ClipboardSnapshot? { nil }
}
@MainActor private final class ProbeWriter: ClipboardWriting {
    func write(_ items: [ClipboardContent], marker: String) -> ClipboardWriteResult { .failed }
}

import Accelerate
extension EditingTests {
    /// The brushed region is convolved on its own; inside the brush it must match a whole-image blur exactly.
    @Test func regionBlurMatchesWholeImageBlurInsideTheBrush() throws {
        let image = PerformanceProbes.screenshot(width: 400, height: 300)
        var document = EditingDocument(canvas: CGSize(width: 200, height: 150), fullScreen: true)
        let brush = EditingStyle(brushSize: 40)
        document.append(EditingMark(tool: .blur, points: [CGPoint(x: 60, y: 70), CGPoint(x: 140, y: 70)], style: brush))
        let rendered = NSBitmapImageRep(cgImage: try EditingRenderer.compose(image, document: document))

        let sigma = Double(max(2, brush.brushSize / 5) * 2), radius = Int(ceil(sigma * 3))
        var kernel = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let sum = kernel.reduce(0, +); kernel = kernel.map { $0 / sum }
        let source = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        source.draw(image, in: CGRect(x: 0, y: 0, width: 400, height: 300))
        let output = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var src = vImage_Buffer(data: source.data, height: 300, width: 400, rowBytes: source.bytesPerRow)
        var dst = vImage_Buffer(data: output.data, height: 300, width: 400, rowBytes: output.bytesPerRow)
        _ = kernel.withUnsafeBufferPointer { vImageSepConvolve_ARGB8888(&src, &dst, nil, 0, 0, $0.baseAddress, UInt32($0.count), $0.baseAddress, UInt32($0.count), 0, nil, vImage_Flags(kvImageEdgeExtend)) }
        let reference = NSBitmapImageRep(cgImage: output.makeImage()!)
        for x in stride(from: 130, through: 270, by: 7) {
            let a = try #require(rendered.colorAt(x: x, y: 140)), b = try #require(reference.colorAt(x: x, y: 140))
            #expect(abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02 && abs(a.blueComponent - b.blueComponent) < 0.02, "x \(x)")
        }
        #expect(rendered.colorAt(x: 200, y: 20) == NSBitmapImageRep(cgImage: image).colorAt(x: 200, y: 20), "Pixels outside the brush are untouched")
    }
}

extension EditingTests {
    @Test func capturedPixelsSkipDecodingAndExportTheSameImage() throws {
        let source = try Self.fixture()
        let pixels = try #require(EditingRenderer.decode(source))
        let mark = EditingMark(tool: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 50)], style: EditingStyle(color: .red, width: 3, filled: true))
        let fast = EditingSession(image: source, decoded: pixels, canvas: CGSize(width: 100, height: 80), fullScreen: true, writer: ProbeImageOutput())
        fast.document.append(mark)
        #expect(fast.sourceImage === pixels)
        let reference = try EditingRenderer.render(source, document: fast.document)
        #expect(try fast.composite() == reference)
        let wrongSize = PerformanceProbes.screenshot(width: 20, height: 20)
        let guarded = EditingSession(image: source, decoded: wrongSize, canvas: CGSize(width: 100, height: 80), fullScreen: true, writer: ProbeImageOutput())
        #expect(guarded.sourceImage?.width == source.width, "Pixels that do not match the PNG are never used")
    }
}
@MainActor private final class ProbeImageOutput: ImageOutputWriting {
    func copyImage(_ image: RasterImage) -> CopyOutcome { .failed }
}
