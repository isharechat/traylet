import AppKit
import Combine
import Testing
import TrayletCore
@testable import TrayletApp

/// Run explicitly with TRAYLET_REFERENCE_PERF=1 and TRAYLET_REFERENCE_PERF_DIR=/absolute/temp/path.
/// A single serialized suite keeps the samples ordered; normal test runs skip all fixture allocation.
@Suite("Reference synthetic performance", .serialized)
@MainActor struct ReferencePerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAYLET_REFERENCE_PERF"] == "1"))
    func syntheticBaseline() async throws {
        let report = try ReferencePerformanceReport()
        try await imageBaselines(report)
        try await clipboardBaselines(report)
        try await textLimits(report)
        try report.finish()
    }

    private func imageBaselines(_ report: ReferencePerformanceReport) async throws {
        for (width, height) in [(3024, 1964), (3840, 2160)] {
            let source = try screenshot(width: width, height: height)
            let png = try EditingRenderer.encode(source)
            for strokes in [0, 8] {
                var document = EditingDocument(canvas: CGSize(width: width / 2, height: height / 2), fullScreen: true)
                for index in 0..<strokes {
                    // Eight disjoint horizontal 220-point strokes at Retina 2x; not eight whole-image blurs.
                    let y = CGFloat(100 + index * 100)
                    document.append(EditingMark(tool: .blur, points: [CGPoint(x: 200, y: y), CGPoint(x: 420, y: y)], style: EditingStyle(brushSize: 40)))
                }
                let scale = ["widthPixels": width, "heightPixels": height, "blurStrokes": strokes, "brushPoints": 40, "backingScale": 2, "sourcePNGBytes": png.pngData.count]
                let composite = try EditingRenderer.compose(source, document: document)
                // The marker lives outside every stroke; validate exact preservation after each operation.
                let expected = try markerColor(source)
                let composedProbe = try markerColor(composite)
                #expect(composedProbe == expected)
                if strokes == 8 {
                    // Independent fixture property: high-frequency columns must visibly soften in a stroke.
                    let original = NSBitmapImageRep(cgImage: source)
                    let blurred = NSBitmapImageRep(cgImage: composite)
                    let a = try #require(original.colorAt(x: 600, y: 200))
                    let b = try #require(blurred.colorAt(x: 600, y: 200))
                    #expect(abs(a.redComponent - b.redComponent) > 0.05)
                }
                try await report.sync("editing.compose", scale: scale, notes: "Already decoded synthetic CGImage; full-screen selection; no PNG encoding. Opaque deterministic textured fixture.", prepare: { () }, operation: { _ in
                    try EditingRenderer.compose(source, document: document)
                }, validate: { _, image in
                    #expect(image.width == width && image.height == height)
                    let actual = try markerColor(image)
                    #expect(actual == expected)
                    try verifyBlur(image, strokes: strokes)
                })
                try await report.sync("editing.pngEncode", scale: scale, notes: "Precomposed CGImage; PNG encode plus RasterImage metadata validation; no compose/decode in measured interval.", prepare: { () }, operation: { _ in
                    try EditingRenderer.encode(composite)
                }, validate: { _, image in
                    #expect(image.width == width && image.height == height)
                    let decoded = try #require(EditingRenderer.decode(image))
                    let actual = try markerColor(decoded)
                    #expect(actual == expected)
                    try verifyBlur(decoded, strokes: strokes)
                })
                try await report.sync("editing.renderPNG", scale: scale, notes: "Full existing export interface: decode source PNG, compose, encode and validate RasterImage; no screen capture/hotkey latency.", prepare: { () }, operation: { _ in
                    try EditingRenderer.render(png, document: document)
                }, validate: { _, image in
                    #expect(image.width == width && image.height == height)
                    let decoded = try #require(EditingRenderer.decode(image))
                    let actual = try markerColor(decoded)
                    #expect(actual == expected)
                    try verifyBlur(decoded, strokes: strokes)
                })
            }
        }
    }

    private func clipboardBaselines(_ report: ReferencePerformanceReport) async throws {
        for count in [100, 500, 1000] {
            for bytes in [4096, 16384] {
                let entries = seedEntries(count: count, bytes: bytes)
                #expect(entries.count == count && entries.allSatisfy { $0.byteCount == bytes && ClipboardPolicy.valid($0.items) })
                let scale = ["entryCount": count, "bytesPerEntry": bytes, "bodyBytes": count * bytes, "historyCapacity": 1000]
                for cold in [true, false] {
                    for miss in [false, true] {
                        let label = "clipboard.search.\(cold ? "cold" : "warm").\(miss ? "miss" : "hit")"
                        try await report.sync(label, scale: scale, notes: "One filteredEntries access; cold=fresh controller display cache (not OS/disk cache); warm=all display rows precomputed. ASCII bodies, case-insensitive query; one hit or no hits. Setup/archive seeding excluded.", prepare: {
                            let fixture = await clipboardFixture(entries)
                            if !cold { for entry in fixture.controller.entries { _ = fixture.controller.display(entry) } }
                            fixture.controller.query = miss ? "MissingTarget" : "needletarget"
                            return fixture
                        }, operation: { fixture in fixture.controller.filteredEntries }, validate: { fixture, result in
                            #expect(result.count == (miss ? 0 : 1))
                            if !miss { #expect(result.first?.id == entries.last?.id) }
                            #expect(fixture.source.reads == 0 && fixture.writer.writes == 0)
                            fixture.controller.stop()
                        })
                    }
                }
                for warmDisplay in [false, true] {
                    for miss in [false, true] {
                        let interval = warmDisplay ? "queryAndResults" : "coldQueryAndResults"
                        try await report.sync("clipboard.\(interval).\(miss ? "miss" : "hit")", scale: scale, notes: "\(warmDisplay ? "Warm" : "Cold, fresh controller") display cache; query assignment plus filteredEntries access in one synchronous interval. Cold includes first row decoding and classification. Includes selection normalization and query invalidation; no SwiftUI drawing or OS/disk cache claim.", prepare: {
                            let fixture = await clipboardFixture(entries)
                            if warmDisplay { for entry in fixture.controller.entries { _ = fixture.controller.display(entry) } }
                            return fixture
                        }, operation: { fixture in
                            fixture.controller.query = miss ? "MissingTarget" : "needletarget"
                            return fixture.controller.filteredEntries
                        }, validate: { fixture, result in
                            #expect(result.count == (miss ? 0 : 1))
                            if !miss { #expect(result.first?.id == entries.last?.id) }
                            #expect(fixture.source.reads == 0 && fixture.writer.writes == 0)
                            fixture.controller.stop()
                        })
                    }
                }
                for duplicate in [true, false] {
                    let incoming = duplicate ? entries.last!.items : [ClipboardContent.text(text(index: 1001, bytes: bytes))]
                    try await report.asynchronous("clipboard.refresh.\(duplicate ? "duplicate" : "new")", scale: scale, notes: "One fake generation advance, content validation/hash, dedup/insertion and prune; memory history, no disk persistence. Duplicate is tail entry; new capture may evict oldest at 1000 capacity.", prepare: {
                        let fixture = await clipboardFixture(entries)
                        fixture.source.generation = 1
                        fixture.source.snapshot = V2ClipboardSnapshot(generation: 1, items: incoming, application: "synthetic.reference")
                        return fixture
                    }, operation: { fixture in await fixture.controller.refresh() }, validate: { fixture, _ in
                        #expect(fixture.source.reads == 1 && fixture.writer.writes == 0)
                        #expect(fixture.controller.entries.count == (duplicate ? count : min(1000, count + 1)))
                        #expect(fixture.controller.entries.first?.items == incoming)
                        #expect(Set(fixture.controller.entries.map(\.digest)).count == fixture.controller.entries.count)
                        fixture.controller.stop()
                    })
                }
                var idleScale = scale; idleScale["pollsPerSample"] = 100
                try await report.asynchronous("clipboard.refresh.idle100", scale: idleScale, notes: "100 refresh calls with unchanged fake generation, fixed clock and selected last row; batched wall time, no 700ms sleeps/timer scheduling. No reads/writes/publications expected.", prepare: {
                    let fixture = await clipboardFixture(entries)
                    fixture.controller.selectedID = entries.last?.id
                    let publications = PublicationCounter()
                    let observation = fixture.controller.objectWillChange.sink { publications.value += 1 }
                    return IdleFixture(clipboard: fixture, publications: publications, observation: observation)
                }, operation: { idle in
                    for _ in 0..<100 { await idle.clipboard.controller.refresh() }
                }, validate: { idle, _ in
                    let fixture = idle.clipboard
                    withExtendedLifetime(idle.observation) {}
                    #expect(idle.publications.value == 0)
                    #expect(fixture.controller.entries.count == count && fixture.controller.selectedID == entries.last?.id)
                    #expect(fixture.source.reads == 0 && fixture.writer.writes == 0)
                    fixture.controller.stop()
                })
            }
        }
    }

    private func textLimits(_ report: ReferencePerformanceReport) async throws {
        for bytes in [1_048_576, 10_485_760] {
            let content = ClipboardContent.text(String(repeating: "a", count: bytes))
            let accepted = bytes == 1_048_576
            let scale = ["entryCount": 1, "textBytes": bytes, "currentItemLimitBytes": ClipboardPolicy.itemBytes]
            try await report.sync("clipboard.textPolicy.\(accepted ? "accepted1MiB" : "rejected10MiB")", scale: scale, notes: "Single ASCII text item. 10MiB exceeds the current 4MiB policy and must be rejected; no limit expansion.", prepare: { () }, operation: { _ in
                ClipboardPolicy.valid([content])
            }, validate: { _, result in #expect(result == accepted) })
            try await report.asynchronous("clipboard.textCapture.\(accepted ? "accepted1MiB" : "rejected10MiB")", scale: scale, notes: "One fake source read at generation 1; accepted item stored in memory, oversized item rejected before insertion/hash.", prepare: {
                let fixture = await clipboardFixture([])
                fixture.source.generation = 1
                fixture.source.snapshot = V2ClipboardSnapshot(generation: 1, items: [content], application: "synthetic.reference")
                return fixture
            }, operation: { fixture in await fixture.controller.refresh() }, validate: { fixture, _ in
                #expect(fixture.source.reads == 1 && fixture.writer.writes == 0)
                #expect(fixture.controller.entries.count == (accepted ? 1 : 0))
                if accepted { #expect(fixture.controller.entries.first?.items == [content]) }
                fixture.controller.stop()
            })
        }
    }

    private struct ClipboardFixture {
        let source: ReferenceClipboardSource
        let writer: ReferenceClipboardWriter
        let controller: ClipboardController
    }
    private final class PublicationCounter { var value = 0 }
    private struct IdleFixture {
        let clipboard: ClipboardFixture
        let publications: PublicationCounter
        let observation: AnyCancellable
    }
    private func clipboardFixture(_ entries: [ClipboardEntry]) async -> ClipboardFixture {
        let source = ReferenceClipboardSource(), writer = ReferenceClipboardWriter()
        var settings = ClipboardSettings(); settings.maximumCount = 1000; settings.saveLocally = true
        let controller = ClipboardController(source: source, writer: writer, archive: ReferenceMemoryArchive(entries: entries), settings: settings, clock: { Self.now })
        await controller.enable(poll: false)
        settings.saveLocally = false
        await controller.updateSettings(settings)
        #expect(controller.entries.count == entries.count && !controller.settings.saveLocally)
        return ClipboardFixture(source: source, writer: writer, controller: controller)
    }
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func seedEntries(count: Int, bytes: Int) -> [ClipboardEntry] {
        (0..<count).map { index in
            let items = [ClipboardContent.text(text(index: index, bytes: bytes, target: index == count - 1))]
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", index))!
            return ClipboardEntry(id: id, digest: ClipboardPolicy.digest(items), items: items,
                                  capturedAt: Self.now.addingTimeInterval(-Double(index)), favorite: false, application: "synthetic.reference")
        }
    }
    private func text(index: Int, bytes: Int, target: Bool = false) -> String {
        let prefix = String(format: "entry-%06d ", index)
        let suffix = target ? " NeedleTarget" : " plain-text"
        return prefix + String(repeating: "x", count: bytes - prefix.utf8.count - suffix.utf8.count) + suffix
    }

    private func screenshot(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * context.bytesPerRow + x * 4
                data[offset] = x % 4 < 2 ? 240 : 16
                data[offset + 1] = UInt8((x / 17 + y / 11) % 256)
                data[offset + 2] = UInt8((x / 7 + y / 19) % 256)
                data[offset + 3] = 255
            }
        }
        // Write image rows directly: CGContext user-space y=0 is not NSBitmapImageRep row=0.
        // This known opaque marker remains far outside every blur stroke.
        for y in 0..<32 {
            for x in 0..<32 {
                let offset = y * context.bytesPerRow + x * 4
                data[offset] = 255; data[offset + 1] = 0; data[offset + 2] = 255; data[offset + 3] = 255
            }
        }
        return try #require(context.makeImage())
    }
    private func markerColor(_ image: CGImage) throws -> [CGFloat] {
        let color = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: 8, y: 8))
        let components = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        try #require(components == [1, 0, 1, 1], "Known magenta marker remains exact through compose/PNG")
        return components
    }
    private func verifyBlur(_ image: CGImage, strokes: Int) throws {
        guard strokes == 8 else { return }
        let color = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: 600, y: 200))
        // Alternating 240/16 columns converge near 128 inside the brush, independent of renderer output.
        try #require(color.redComponent > 0.35 && color.redComponent < 0.65)
    }
}
