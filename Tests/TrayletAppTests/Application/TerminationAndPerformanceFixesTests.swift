import AppKit
import Foundation
import Testing
import TrayletCore
@testable import TrayletApp

@Suite("Termination and Runtime Fixes") @MainActor struct TerminationAndPerformanceFixesTests {
    @Test func reentrantTerminationDuringConfirmationCancelsWithoutNesting() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-term-reentrant-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let coordinator = AppCoordinator(directory: dir)
        var replies: [Bool] = []
        coordinator.finishTermination = { replies.append($0) }
        let pixels = PerformanceProbes.screenshot(width: 40, height: 30)
        coordinator.editor.present(pixels: pixels, screenFrame: CGRect(x: 0, y: 0, width: 40, height: 30), initiallyFullScreen: true)
        var promptCalls = 0
        var reentrantReply: NSApplication.TerminateReply?
        coordinator.confirmQuitWithOpenEditor = {
            promptCalls += 1
            reentrantReply = coordinator.requestTermination()
            return false
        }
        let first = coordinator.requestTermination()
        #expect(first == .terminateCancel)
        #expect(reentrantReply == .terminateCancel)
        #expect(promptCalls == 1)
        #expect(replies.isEmpty)
        coordinator.editor.cancel(restoreFocus: false)
        await coordinator.clipboard.shutdownAndWait()
    }

    @Test func terminationRepliesAfterTimeoutEvenIfClipboardShutdownStalls() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-term-timeout-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let coordinator = AppCoordinator(directory: dir)
        coordinator.shutdownTimeoutNanoseconds = 80_000_000 // 80ms
        var replyCount = 0
        coordinator.finishTermination = { allowed in
            if allowed { replyCount += 1 }
        }
        // Queue a stalled mutation on clipboard so shutdownAndWait() blocks past the 80ms timeout.
        let gate = StallGate()
        coordinator.clipboard.runMutation { await gate.wait() }
        let reply = coordinator.requestTermination()
        #expect(reply == .terminateLater)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while replyCount == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(replyCount == 1)
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(replyCount == 1, "Termination must reply exactly once even after late shutdown completes")
    }

    @Test func floatingImageControllerCapsPanelsAndClosesAll() {
        let controller = FloatingImageController()
        let image = PerformanceProbes.screenshot(width: 100, height: 80)
        for _ in 0..<(FloatingImageController.maximumPanels + 3) {
            controller.present(cgImage: image, initialFrame: CGRect(x: 0, y: 0, width: 100, height: 80))
        }
        #expect(controller.panelCount == FloatingImageController.maximumPanels)
        controller.closeAll()
        #expect(controller.panelCount == 0)
    }

    @Test func rejectedCopiesCleanStartupAndCleanShutdownDoNotWriteArchive() async {
        let archive = CountingClipboardArchive()
        let source = MemoryClipboardSource()
        let store = ClipboardController(source: source, writer: MemoryClipboardWriter(), archive: archive)
        await store.enable()
        #expect(await archive.replaceCalls == 0, "Clean startup with nothing pruned must not rewrite archive.json")

        // Rejected copy (sensitive / excluded / invalid) must not trigger archive.replace.
        source.value = .init(generation: 1, items: [.text("secret")], application: "test.app", sensitive: true)
        await store.refresh()
        #expect(await archive.replaceCalls == 0)

        // Valid copy triggers exactly one write.
        source.value = .init(generation: 2, items: [.text("normal")], application: "test.app")
        await store.refresh()
        #expect(await archive.replaceCalls == 1)

        // Clean shutdown with no pending mutations must not rewrite archive.json again.
        await store.shutdown()
        #expect(await archive.replaceCalls == 1)
    }

    @Test func favoritesAndFullHistoryPersistSeparatelyWithoutBudgetCollision() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-budget-split-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = ClipboardArchive(directory: dir)
        let source = MemoryClipboardSource()
        let store = ClipboardController(source: source, writer: MemoryClipboardWriter(), archive: archive)
        await store.enable()

        // 1 favorite (~4 MiB) + 8 ordinary items (~32 MiB) = ~36 MiB total (> 32 MiB combined).
        let body = String(repeating: "a", count: ClipboardPolicy.itemBytes - 16)
        source.value = .init(generation: 1, items: [.text("fav-" + body)], application: "test.app")
        await store.refresh()
        let favID = try #require(store.entries.first?.id)
        await store.toggleFavorite(favID)

        for gen in 2...9 {
            source.value = .init(generation: gen, items: [.text("hist-\(gen)-" + body)], application: "test.app")
            await store.refresh()
        }
        #expect(store.message == nil, "Separate history/favorite archives must not fail with Failure.damaged when combined size exceeds 32 MiB")
        #expect(store.entries.filter(\.favorite).count == 1)
        #expect(store.entries.filter { !$0.favorite }.count == 8)
        await store.shutdown()

        let reopened = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: ClipboardArchive(directory: dir))
        await reopened.enable()
        #expect(reopened.entries.filter(\.favorite).count == 1)
        #expect(reopened.entries.filter { !$0.favorite }.count == 8)
        await reopened.shutdown()
    }

    @Test func archiveValidationCacheStillRejectsTamperedEntry() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-tamper-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = ClipboardArchive(directory: dir)
        let items: [ClipboardContent] = [.text("original")]
        let valid = ClipboardEntry(id: UUID(), digest: ClipboardPolicy.digest(items), items: items, capturedAt: Date(), favorite: false, application: "test.app")
        try await archive.replace([valid], revision: 1)
        let tampered = ClipboardEntry(id: valid.id, digest: valid.digest, items: [.text("tampered")], capturedAt: valid.capturedAt, favorite: false, application: "test.app")
        await #expect(throws: ClipboardArchive.Failure.self) {
            try await archive.replace([tampered], revision: 2)
        }
    }

    @Test func incrementalBlurCacheAndPixelOnlySessionMatchFullCompose() throws {
        let pixels = PerformanceProbes.screenshot(width: 400, height: 300)
        let session = EditingSession(pixels: pixels, canvas: CGSize(width: 200, height: 150), fullScreen: true, writer: TestNoopImageWriter())
        let firstStroke = EditingMark(tool: .blur, points: [CGPoint(x: 40, y: 50), CGPoint(x: 120, y: 50)], style: EditingStyle(brushSize: 28))
        let secondStroke = EditingMark(tool: .blur, points: [CGPoint(x: 60, y: 100), CGPoint(x: 150, y: 100)], style: EditingStyle(brushSize: 28))
        session.document.append(firstStroke)
        let afterFirst = try #require(session.blurredSourceImage())
        #expect(afterFirst.width == 400 && afterFirst.height == 300)
        session.document.append(secondStroke)
        let incremental = try #require(session.blurredSourceImage())
        let full = try EditingRenderer.composeBlurredSource(pixels, document: session.document)

        let a = NSBitmapImageRep(cgImage: incremental)
        let b = NSBitmapImageRep(cgImage: full)
        for y in stride(from: 20, to: 280, by: 20) {
            for x in stride(from: 20, to: 380, by: 20) {
                let ca = try #require(a.colorAt(x: x, y: y))
                let cb = try #require(b.colorAt(x: x, y: y))
                #expect(abs(ca.redComponent - cb.redComponent) < 0.01)
                #expect(abs(ca.greenComponent - cb.greenComponent) < 0.01)
                #expect(abs(ca.blueComponent - cb.blueComponent) < 0.01)
            }
        }
        let exported = try session.composite()
        #expect(exported.width == 400 && exported.height == 300)
    }

    @Test func translationFlowTracksContentWithoutTrimmingAllocation() {
        let flow = TranslationFlow()
        #expect(!flow.hasTranslatableContent)
        flow.input = "   \n\t  "
        #expect(!flow.hasTranslatableContent)
        flow.input = "  Hello"
        #expect(flow.hasTranslatableContent)
        flow.input = ""
        #expect(!flow.hasTranslatableContent)
    }
}

private actor StallGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume(); waiter = nil
    }
}

private actor CountingClipboardArchive: ClipboardArchiving {
    private(set) var replaceCalls = 0
    private var stored: [ClipboardEntry] = []
    func load() -> [ClipboardEntry] { stored }
    func replace(_ entries: [ClipboardEntry], revision: UInt64) { replaceCalls += 1; stored = entries }
    func clear(revision: UInt64) { stored = [] }
    func loadSettings() -> ClipboardSettings? { nil }
    func saveSettings(_ settings: ClipboardSettings) {}
    func loadFavorites() -> [ClipboardEntry] { [] }
    func replaceFavorites(_ entries: [ClipboardEntry], revision: UInt64) {}
    func clearFavorites(revision: UInt64) {}
}

@MainActor private final class TestNoopImageWriter: ImageOutputWriting {
    func copyImage(_ image: RasterImage) -> CopyOutcome { .copied }
}
