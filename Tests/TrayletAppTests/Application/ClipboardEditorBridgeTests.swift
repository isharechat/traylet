import AppKit
import ImageIO
import Testing
import TrayletCore
@testable import TrayletApp

@Suite("Clipboard Editor Bridge") @MainActor struct ClipboardEditorBridgeTests {
    @Test func realFeatureOpensCopyOfOneImageAndReturnsToTheSameHistory() async throws {
        let fixture = try await Fixture()
        defer { fixture.editor.cancel(); fixture.feature.shutdown(); try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try #require(fixture.feature.controller.selectedEntry)
        await fixture.feature.controller.toggleFavorite(original.id)
        let favorite = try #require(fixture.feature.controller.selectedEntry)
        fixture.feature.controller.query = "synthetic"
        fixture.feature.present()
        let reads = fixture.source.reads
        await fixture.feature.editImage(original.id, itemIndex: 1)?.value
        let canvas = try #require(fixture.canvas)
        #expect(fixture.editor.isOpen && fixture.editorPresentations == 1 && fixture.dismissals == 1)
        #expect(canvas.session.sourceImage === fixture.preparedPixels)
        let export = try canvas.session.composite()
        #expect(export.width == 96 && export.height == 48)
        #expect(fixture.feature.controller.entries == [favorite])
        #expect(fixture.writer.writes.isEmpty && fixture.source.reads == reads && fixture.imageWriter.writes == 0)
        fixture.editor.cancel()
        #expect(!fixture.editor.isOpen && fixture.historyPresentations == 2)
        #expect(fixture.feature.controller.query == "synthetic" && fixture.feature.controller.selectedID == original.id)
        #expect(!fixture.bridge.complete())
        await fixture.feature.shutdownAndWait()
    }
    @Test func occupiedEditorDoesNotDecodeOrReplaceAndAnotherAppDoesNotLoseFocus() async throws {
        let fixture = try await Fixture()
        defer { fixture.editor.cancel(); fixture.feature.shutdown(); try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try #require(fixture.feature.controller.selectedEntry)
        #expect(fixture.editor.presentImported(image: fixture.prepared.image, decoded: fixture.prepared.pixels, availableFrame: CGRect(x: 0, y: 0, width: 900, height: 700)))
        let existing = try #require(fixture.canvas)
        #expect(fixture.feature.editImage(original.id, itemIndex: 1) == nil)
        #expect(fixture.editorPresentations == 1 && fixture.canvas === existing)
        #expect(fixture.feature.imageEditing.message == "请先完成或关闭当前编辑。")
        fixture.editor.cancel()
        fixture.returnAllowed = false
        await fixture.feature.editImage(original.id, itemIndex: 1)?.value
        fixture.editor.cancel()
        #expect(fixture.historyPresentations == 0 && !fixture.bridge.complete())
        #expect(fixture.writer.writes.isEmpty && fixture.imageWriter.writes == 0)
        await fixture.feature.shutdownAndWait()
    }
    @Test(arguments: Withdrawal.allCases) func navigationAndDeletionInvalidatePendingOpen(_ withdrawal: Withdrawal) async throws {
        let gate = BridgeImageGate()
        let fixture = try await Fixture(imageEditing: ClipboardImageEditing(prepare: { _ in await gate.wait() }))
        defer { fixture.editor.cancel(); fixture.feature.shutdown(); try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try #require(fixture.feature.controller.selectedEntry)
        let task = try #require(fixture.feature.editImage(original.id, itemIndex: 1))
        await gate.waitUntilPending()
        switch withdrawal {
        case .query: fixture.feature.controller.query = "missing"
        case .filter: fixture.feature.controller.favoritesOnly = true
        case .selection: fixture.feature.controller.selectedID = nil
        case .delete: await fixture.feature.controller.delete(original.id)
        case .dismiss: fixture.feature.dismiss()
        case .shutdown: await fixture.feature.shutdownAndWait()
        }
        await gate.finish(fixture.prepared)
        await task.value
        #expect(!fixture.editor.isOpen && fixture.editorPresentations == 0 && !fixture.feature.imageEditing.isPreparing)
        #expect(fixture.writer.writes.isEmpty && fixture.imageWriter.writes == 0)
        await fixture.feature.shutdownAndWait()
    }
    @Test func nativeListMoveKeepsOrdinaryItemsAndRejectsSearchSubset() async throws {
        let fixture = try await Fixture()
        defer { fixture.feature.shutdown(); try? FileManager.default.removeItem(at: fixture.directory) }
        for generation in 2...4 {
            fixture.source.value = .init(generation: generation, items: [.text("synthetic \(generation)")], application: "synthetic.app")
            await fixture.feature.controller.refresh()
        }
        let ids = Array(fixture.feature.controller.entries.prefix(2).map(\.id))
        for id in ids { await fixture.feature.controller.toggleFavorite(id) }
        let before = fixture.feature.controller.entries
        #expect(await fixture.feature.moveFavorites(from: IndexSet(integer: 0), to: 2))
        #expect(fixture.feature.controller.orderedFavoriteIDs == Array(ids.reversed()))
        #expect(Array(fixture.feature.controller.entries.dropFirst(2)) == Array(before.dropFirst(2)))
        fixture.feature.controller.query = "synthetic"
        #expect(!(await fixture.feature.moveFavorites(from: IndexSet(integer: 0), to: 2)))
        fixture.feature.controller.query = ""
        #expect(!(await fixture.feature.moveFavorites(from: IndexSet(integer: 2), to: 0)))
        #expect(!(await fixture.feature.moveFavorites(from: IndexSet(integer: 0), to: 3)))
        #expect(fixture.writer.writes.isEmpty)
        await fixture.feature.shutdownAndWait()
    }
    @Test func queuedDragCannotApplyOldRowOffsetsToNewFavorites() async throws {
        let fixture = try await Fixture()
        defer { fixture.feature.shutdown(); try? FileManager.default.removeItem(at: fixture.directory) }
        for generation in 2...4 {
            fixture.source.value = .init(generation: generation, items: [.text("synthetic \(generation)")], application: "synthetic.app")
            await fixture.feature.controller.refresh()
        }
        let ids = fixture.feature.controller.entries.map(\.id)
        for id in ids.prefix(2) { await fixture.feature.controller.toggleFavorite(id) }
        let move = fixture.feature.queueFavoriteMove(from: IndexSet(integer: 0), to: 2)
        await fixture.feature.controller.toggleFavorite(ids[2])
        #expect(!(await move.value))
        #expect(fixture.feature.controller.orderedFavoriteIDs == Array(ids.prefix(3)))
        await fixture.feature.shutdownAndWait()
    }
    enum Withdrawal: CaseIterable { case query, filter, selection, delete, dismiss, shutdown }
}

@MainActor private final class Fixture {
    let source = MemoryClipboardSource(), writer = MemoryClipboardWriter(), imageWriter = BridgeImageWriter()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-image-route-" + UUID().uuidString)
    let feature: ClipboardFeature, editor: CaptureEditorController
    let prepared: ClipboardPreparedImage
    let presentation: BridgePresentation
    var bridge: ClipboardEditorBridge!
    var canvas: EditingCanvasView? { presentation.canvas }
    var preparedPixels: CGImage?
    var historyPresentations: Int { presentation.history }
    var editorPresentations: Int { presentation.editors }
    var dismissals: Int { presentation.dismissals }
    var returnAllowed = true
    init(imageEditing: ClipboardImageEditing? = nil) async throws {
        _ = NSApplication.shared
        let context = try #require(CGContext(data: nil, width: 96, height: 48, bitsPerComponent: 8, bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 96, height: 48))
        let data = NSMutableData(), image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); #expect(CGImageDestinationFinalize(destination))
        prepared = try await ClipboardImageDecoder.prepare(data as Data)
        // The spy returns the same prepared CGImage so the integration can assert pointer reuse.
        let prepared = prepared
        let presentation = BridgePresentation(); self.presentation = presentation
        feature = ClipboardFeature(directory: directory, source: source, writer: writer,
                                   imageEditing: imageEditing ?? ClipboardImageEditing(prepare: { _ in prepared }),
                                   presentWindow: { window in presentation.history += 1; presentation.historyPanel = window },
                                   dismissWindow: { presentation.dismissals += 1; $0.orderOut(nil) })
        editor = CaptureEditorController(writer: imageWriter, presentPanel: { _, view in presentation.editors += 1; presentation.canvas = view as? EditingCanvasView })
        bridge = ClipboardEditorBridge(clipboard: feature, editor: editor, availableFrame: { CGRect(x: -900, y: 40, width: 850, height: 650) }, shouldReturn: { [weak self] in self?.returnAllowed ?? false })
        editor.onComplete = { [weak self] in _ = self?.bridge.complete() }
        await feature.start(poll: false)
        source.value = .init(generation: 1, items: [.text("synthetic original"), .init(representations: ["public.png": data as Data])], application: "synthetic.app")
        await feature.controller.refresh()
        preparedPixels = prepared.pixels
    }
}
@MainActor private final class BridgePresentation {
    var canvas: EditingCanvasView?, historyPanel: NSPanel?
    var history = 0, editors = 0, dismissals = 0
}
@MainActor private final class BridgeImageWriter: ImageOutputWriting {
    var writes = 0
    func copyImage(_ image: RasterImage) -> CopyOutcome { writes += 1; return .copied }
}
private actor BridgeImageGate {
    private var continuation: CheckedContinuation<ClipboardPreparedImage, Never>?
    func wait() async -> ClipboardPreparedImage { await withCheckedContinuation { continuation = $0 } }
    func waitUntilPending() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if continuation != nil { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Preparation did not enter the gate")
    }
    func finish(_ image: ClipboardPreparedImage) { continuation?.resume(returning: image); continuation = nil }
}
