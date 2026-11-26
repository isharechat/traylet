import AppKit
import ImageIO
import Testing
import TrayletCore
@testable import TrayletApp

@Suite("Clipboard Image Editing") @MainActor struct ClipboardImageEditingTests {
    @Test func pngUsesOriginalBytesAndOnePreparedPixelBuffer() async throws {
        let data = try imageData(width: 96, height: 48)
        let result = try await ClipboardImageDecoder.prepare(data)
        #expect(result.image.pngData == data)
        #expect(result.image.width == 96 && result.image.height == 48)
        #expect(result.pixels.width == 96 && result.pixels.height == 48)
    }
    @Test func invalidOrOversizedMetadataIsRejectedBeforeDecode() async throws {
        await #expect(throws: (any Error).self) { try await ClipboardImageDecoder.prepare(Data("not an image".utf8)) }
        let wide = try imageData(width: 5000, height: 3201)
        await #expect(throws: (any Error).self) { try await ClipboardImageDecoder.prepare(wide) }
    }
    @Test func openingIsSingleFlightAndCancellationRejectsLateImage() async throws {
        let gate = ImagePreparationGate()
        let prepared = try await ClipboardImageDecoder.prepare(imageData(width: 64, height: 32))
        let editing = ClipboardImageEditing(prepare: { _ in await gate.wait() })
        let entry = makeEntry([ClipboardContent(representations: ["public.png": prepared.image.pngData])])
        var opens = 0
        let task = try #require(editing.begin(entry: entry, itemIndex: 0, isCurrent: { true }, open: { _ in opens += 1; return true }))
        #expect(editing.isPreparing)
        #expect(editing.begin(entry: entry, itemIndex: 0, isCurrent: { true }, open: { _ in opens += 1; return true }) == nil)
        await gate.waitUntilPending()
        editing.cancel()
        await gate.finish(prepared)
        await task.value
        #expect(opens == 0 && !editing.isPreparing)
    }
    @Test func selectedImageOnlyAndSourceRemainUntouched() async throws {
        let one = try imageData(width: 80, height: 40), two = try imageData(width: 40, height: 80)
        let entry = makeEntry([.text("keep text"), .init(representations: ["public.png": one]), .init(representations: ["public.png": two])])
        let editing = ClipboardImageEditing()
        var result: ClipboardPreparedImage?
        await editing.begin(entry: entry, itemIndex: 2, isCurrent: { true }, open: { result = $0; return true })?.value
        #expect(result?.image.pngData == two && result?.image.width == 40)
        #expect(entry.items[1].imageData == one && entry.items[0].plainText == "keep text")
        #expect(ClipboardImageEditing.imageIndices(in: entry) == [1, 2])
        #expect(editing.begin(entry: entry, itemIndex: 0, isCurrent: { true }, open: { _ in Issue.record("Text cannot open"); return true }) == nil)
    }
    @Test func staleSelectionAndBusyEditorDoNotConsumeOriginal() async throws {
        let data = try imageData(width: 80, height: 40)
        let entry = makeEntry([.init(representations: ["public.png": data])])
        let editing = ClipboardImageEditing()
        var opens = 0
        await editing.begin(entry: entry, itemIndex: 0, isCurrent: { false }, open: { _ in opens += 1; return true })?.value
        #expect(opens == 0)
        await editing.begin(entry: entry, itemIndex: 0, isCurrent: { true }, open: { _ in opens += 1; return false })?.value
        #expect(opens == 1 && editing.message == "请先完成或关闭当前编辑。")
        #expect(entry.items.first?.imageData == data && !editing.isPreparing)
    }
    @Test(arguments: ["public.jpeg", "public.tiff"]) func convertsOnlyEditingCopyAndNormalizesOrientation(_ type: String) async throws {
        let png = try imageData(width: 96, height: 48)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let pixels = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let original = output as Data
        let result = try await ClipboardImageDecoder.prepare(original)
        #expect(result.image.width == 48 && result.image.height == 96)
        #expect(result.pixels.width == 48 && result.pixels.height == 96)
        #expect(result.image.pngData.prefix(8) == png.prefix(8))
        #expect(result.image.pngData != original)
        #expect(original == output as Data)
    }
    @Test func acceptsBudgetEdgeWithoutCreatingAnotherPixelBufferInEditor() async throws {
        let data = try imageData(width: 4000, height: 4000)
        #expect(data.count < ClipboardPolicy.itemBytes)
        let result = try await ClipboardImageDecoder.prepare(data)
        let session = EditingSession(image: result.image, decoded: result.pixels, canvas: CGSize(width: 400, height: 400), fullScreen: true, writer: BudgetImageWriter())
        #expect(session.sourceImage === result.pixels)
        #expect(result.image.pngData == data && result.pixels.width * result.pixels.height == ClipboardPolicy.imagePixels)
    }
    @Test func canceledDecodeFailsAndAnOrdinaryRetryStillWorks() async throws {
        let data = try imageData(width: 96, height: 48)
        let task = Task { try await ClipboardImageDecoder.prepare(data) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Canceled decode must not deliver pixels") }
        catch is CancellationError {}
        catch { Issue.record("Expected cancellation, not \(type(of: error))") }
        #expect(try await ClipboardImageDecoder.prepare(data).image.pngData == data)
    }
    @Test func preparationFailureIsSanitizedAndCanBeRetried() async throws {
        let prepared = try await ClipboardImageDecoder.prepare(imageData(width: 96, height: 48))
        let attempts = PreparationAttempts()
        let editing = ClipboardImageEditing(prepare: { _ in
            if await attempts.next() == 1 { throw FeatureIssue.unavailable("synthetic private details") }
            return prepared
        })
        let entry = makeEntry([.init(representations: ["public.png": prepared.image.pngData])])
        var opens = 0
        await editing.begin(entry: entry, itemIndex: 0, isCurrent: { true }, open: { _ in opens += 1; return true })?.value
        #expect(editing.message == "图片暂时无法打开。" && !editing.isPreparing && opens == 0)
        await editing.begin(entry: entry, itemIndex: 0, isCurrent: { true }, open: { _ in opens += 1; return true })?.value
        #expect(editing.message == nil && !editing.isPreparing && opens == 1)
    }
    private func makeEntry(_ items: [ClipboardContent]) -> ClipboardEntry {
        .init(id: UUID(), digest: ClipboardPolicy.digest(items), items: items, capturedAt: Date(), favorite: false, application: "synthetic.app")
    }
    private func imageData(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage()), data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination)); return data as Data
    }
}

private actor ImagePreparationGate {
    private var continuation: CheckedContinuation<ClipboardPreparedImage, Never>?
    func wait() async -> ClipboardPreparedImage { await withCheckedContinuation { continuation = $0 } }
    func waitUntilPending() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if continuation != nil { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Preparation did not reach the synthetic gate")
    }
    func finish(_ image: ClipboardPreparedImage) { continuation?.resume(returning: image); continuation = nil }
}
private actor PreparationAttempts {
    private var attempts = 0
    func next() -> Int { attempts += 1; return attempts }
}
@MainActor private final class BudgetImageWriter: ImageOutputWriting {
    func copyImage(_ image: RasterImage) -> CopyOutcome { Issue.record("Opening must not copy"); return .failed }
}
