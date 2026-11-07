import Foundation
import Testing
@testable import TrayletApp

@Suite("Clipboard Concurrency") @MainActor struct ClipboardConcurrencyTests {
    @Test func deletingAllFavoritesWhileStartupLoadsCannotReviveDeletedFavorites() async {
        let archive = SuspendedFavoritesArchive()
        let source = MemoryClipboardSource()
        let store = ClipboardController(source: source, writer: MemoryClipboardWriter(), archive: archive)
        let startup = Task { await store.enable() }
        await archive.waitUntilLoading()
        await store.deleteAllFavorites()
        await archive.releaseLoad()
        await startup.value
        #expect(store.entries.isEmpty && !store.hasFavorites)
        source.value = .init(generation: 1, items: [.text("new copy after deletion")], application: "test.app")
        await store.refresh()
        #expect(store.entries.map(\.plainText) == ["new copy after deletion"])
        await store.shutdown()
    }
    @Test func changingLimitDuringArchiveLoadStillLoadsUnderCurrentLimit() async {
        let archive = SuspendedClipboardArchive()
        var settings = ClipboardSettings()
        let store = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: archive, settings: settings)
        let enabling = Task { await store.enable() }
        await archive.waitUntilLoading()
        settings.maximumCount = 1; await store.updateSettings(settings)
        await archive.releaseLoad(); await enabling.value
        #expect(store.entries.first?.plainText == "stale synthetic saved body")
        #expect(await archive.saved.count == 1)
    }
    @Test func clearWhileArchiveLoadIsSuspendedCannotReviveOldBody() async {
        let archive = SuspendedClipboardArchive()
        let settings = ClipboardSettings()
        let store = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: archive, settings: settings)
        let enabling = Task { await store.enable() }
        await archive.waitUntilLoading()
        await store.clear()
        await archive.releaseLoad()
        await enabling.value
        #expect(store.entries.isEmpty)
        #expect(await archive.saved.isEmpty)
    }
    @Test func shutdownDuringLoadDoesNotPublishOrPersistLoadedBody() async {
        let archive = SuspendedClipboardArchive()
        let settings = ClipboardSettings()
        let store = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: archive, settings: settings)
        let enabling = Task { await store.enable() }
        await archive.waitUntilLoading()
        await store.shutdown()
        await archive.releaseLoad(); await enabling.value
        #expect(!store.enabled && store.entries.isEmpty)
        #expect(await archive.saved.isEmpty)
    }
    @Test func clearDuringStartupStillCollectsSubsequentCopies() async throws {
        let archive = SuspendedClipboardArchive(); let source = MemoryClipboardSource()
        let settings = ClipboardSettings()
        let store = ClipboardController(source: source, writer: MemoryClipboardWriter(), archive: archive, settings: settings)
        let startup = Task { await store.enable(poll: true) }
        await archive.waitUntilLoading()
        await store.clear()
        await archive.releaseLoad(); await startup.value
        source.value = .init(generation: 1, items: [.text("after clear")], application: "test.app")
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while store.entries.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.enabled && store.entries.map(\.plainText) == ["after clear"])
        await store.shutdown()
    }
}

actor SuspendedClipboardArchive: V2ClipboardArchiving {
    private var loading = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<[ClipboardEntry], Never>?
    private(set) var saved: [ClipboardEntry] = []
    func load() async throws -> [ClipboardEntry] {
        loading = true
        return await withCheckedContinuation { continuation in pending = continuation; waiter?.resume(); waiter = nil }
    }
    func waitUntilLoading() async { if loading { return }; await withCheckedContinuation { waiter = $0 } }
    func releaseLoad() {
        let items: [ClipboardContent] = [.text("stale synthetic saved body")]
        pending?.resume(returning: [ClipboardEntry(id: UUID(), digest: ClipboardPolicy.digest(items), items: items, capturedAt: Date(), favorite: false, application: "test.app")]); pending = nil
    }
    func replace(_ entries: [ClipboardEntry], revision: UInt64) { saved = entries }
    func clear(revision: UInt64) { saved = [] }
    func loadSettings() -> ClipboardSettings? { nil }
    func saveSettings(_ settings: ClipboardSettings) {}
    func loadFavorites() -> [ClipboardEntry] { [] }
    func replaceFavorites(_ entries: [ClipboardEntry], revision: UInt64) {}
    func clearFavorites(revision: UInt64) {}
}

/// Suspends only the file-load boundary, so the UI can finish an explicit destructive action first.
actor SuspendedFavoritesArchive: V2ClipboardArchiving {
    private var loading = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<[ClipboardEntry], Never>?
    func load() -> [ClipboardEntry] { [] }
    func replace(_ entries: [ClipboardEntry], revision: UInt64) {}
    func clear(revision: UInt64) {}
    func loadSettings() -> ClipboardSettings? { nil }
    func saveSettings(_ settings: ClipboardSettings) {}
    func loadFavorites() async -> [ClipboardEntry] {
        loading = true
        return await withCheckedContinuation { pending = $0; waiter?.resume(); waiter = nil }
    }
    func waitUntilLoading() async { if !loading { await withCheckedContinuation { waiter = $0 } } }
    func releaseLoad() {
        let items: [ClipboardContent] = [.text("deleted synthetic favorite")]
        pending?.resume(returning: [ClipboardEntry(id: UUID(), digest: ClipboardPolicy.digest(items), items: items, capturedAt: Date(), favorite: true, application: "test.app")])
        pending = nil
    }
    func replaceFavorites(_ entries: [ClipboardEntry], revision: UInt64) {}
    func clearFavorites(revision: UInt64) {}
}
