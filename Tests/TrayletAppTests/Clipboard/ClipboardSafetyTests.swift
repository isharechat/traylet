import AppKit
import Testing
@testable import TrayletApp

@Suite("Clipboard Safety") @MainActor struct ClipboardSafetyTests {
    @Test func englishClipboardLabelsLeaveCapturedContentUntouched() async {
        let localization = V2Localization(languageCode: "en")
        #expect(localization.text("复制") == "Copy")
        #expect(localization.text("删除") == "Delete")
        #expect(localization.text("取消") == "Cancel")
        #expect(localization.text("暂无匹配历史") == "No Matching History")
        let source = MemoryClipboardSource(); let store = ClipboardController(source: source, writer: MemoryClipboardWriter())
        await store.enable()
        source.value = .init(generation: 1, items: [.text("用户正文 · 复制")], application: "com.example.中文")
        await store.refresh()
        #expect(store.entries.first?.plainText == "用户正文 · 复制")
        #expect(store.entries.first?.application == "com.example.中文")
    }
    @Test func deletionNeedsConfirmationAndKeepsTheRequestedIdentity() async throws {
        let source = MemoryClipboardSource(); let store = ClipboardController(source: source, writer: MemoryClipboardWriter())
        await store.enable()
        for generation in 1...2 {
            source.value = .init(generation: generation, items: [.text("entry \(generation)")], application: "test.app")
            await store.refresh()
        }
        let requested = try #require(store.entries.last?.id)
        let other = try #require(store.entries.first?.id)
        store.requestDeletion(requested)
        #expect(store.entries.count == 2 && store.pendingDeletionID == requested)
        store.cancelDeletion()
        await store.confirmDeletion()
        #expect(store.entries.count == 2)
        store.requestDeletion(requested); store.selectedID = other
        await store.confirmDeletion()
        #expect(store.entries.map(\.id) == [other])
        store.requestDeletion(other)
        await store.delete(other)
        source.value = .init(generation: 3, items: [.text("new arrival")], application: "test.app")
        await store.refresh(); await store.confirmDeletion()
        #expect(store.entries.first?.plainText == "new arrival")
        #expect(store.pendingDeletionID == nil)
    }
    @Test func thousandEntryLimitAndBackwardClockKeepBoundedHistory() async {
        let source = MemoryClipboardSource(); let clock = ClipboardTestClock()
        let store = ClipboardController(source: source, writer: MemoryClipboardWriter(), clock: { clock.now })
        var settings = ClipboardSettings(); settings.maximumCount = 1001
        await store.updateSettings(settings)
        #expect(store.settings.maximumCount == 1000)
        await store.enable()
        let started = ContinuousClock.now
        for generation in 1...1001 {
            source.value = .init(generation: generation, items: [.text("synthetic \(generation)")], application: "test.app")
            await store.refresh()
        }
        #expect(store.entries.count == 1000)
        #expect(store.entries.last?.plainText == "synthetic 2")
        for _ in 0..<100 { await store.refresh() }
        print("Clipboard synthetic 1001 inserts + 100 unchanged polls: \(started.duration(to: .now))")
        clock.now.addTimeInterval(-120)
        await store.refresh()
        #expect(store.entries.isEmpty)
        source.value = .init(generation: 1002, items: [.text("after clock correction")], application: "test.app")
        await store.refresh()
        #expect(store.entries.first?.plainText == "after clock correction")
    }
    @Test func completeStableDigestSeparatesAttachedRepresentationsAndFarBytes() async {
        let source = MemoryClipboardSource(); let store = ClipboardController(source: source, writer: MemoryClipboardWriter())
        await store.enable()
        var item = ClipboardContent.text(String(repeating: "a", count: 20_000) + "b")
        source.value = .init(generation: 1, items: [item], application: "test.app"); await store.refresh()
        let firstID = store.entries[0].id
        source.value = .init(generation: 2, items: [item], application: "test.app"); await store.refresh()
        #expect(store.entries.count == 1 && store.entries[0].id == firstID)
        item.representations["public.html"] = Data("<b>text</b>".utf8)
        source.value = .init(generation: 3, items: [item], application: "test.app"); await store.refresh()
        #expect(store.entries.count == 2)
        source.value = .init(generation: 4, items: [.text(String(repeating: "a", count: 20_000) + "c")], application: "test.app"); await store.refresh()
        #expect(store.entries.count == 3)
        #expect(ClipboardPolicy.digest([.text("ab"), .text("c")]) != ClipboardPolicy.digest([.text("a"), .text("bc")]))
    }
    @Test func rejectedChangeIsAllOrNothing() async {
        let source = MemoryClipboardSource(); let store = ClipboardController(source: source, writer: MemoryClipboardWriter())
        await store.enable()
        let changes: [V2ClipboardSnapshot] = [
            .init(generation: 1, items: [.text("normal")], application: "test.app", sensitive: true),
            .init(generation: 2, items: [.text("normal"), .init(representations: ["public.file-url": Data("file:///secret".utf8)])], application: "test.app"),
            .init(generation: 3, items: Array(repeating: .text("x"), count: 17), application: "test.app"),
            .init(generation: 4, items: [.text(String(repeating: "x", count: ClipboardPolicy.itemBytes + 1))], application: "test.app"),
            .init(generation: 5, items: [.text("unknown owner")], application: ""),
            .init(generation: 6, items: [.init(representations: ["public.png": Data([0, 1, 2])])], application: "test.app")
        ]
        for change in changes { source.value = change; await store.refresh(); #expect(store.entries.isEmpty) }
    }
    @Test func searchFavoriteDeleteLimitsAndCopyFailures() async {
        let source = MemoryClipboardSource(); let writer = MemoryClipboardWriter(); let store = ClipboardController(source: source, writer: writer)
        var settings = ClipboardSettings(); settings.maximumCount = 2; settings.retentionDays = 99
        await store.updateSettings(settings)
        #expect(store.settings.retentionDays == 30)
        await store.enable()
        for generation in 1...3 { source.value = .init(generation: generation, items: [.text("entry \(generation)")], application: "source.app"); await store.refresh() }
        #expect(store.entries.map(\.plainText) == ["entry 3", "entry 2"])
        let id = store.entries[0].id; await store.toggleFavorite(id); store.favoritesOnly = true
        #expect(store.filteredEntries.count == 1)
        store.query = "ENTRY 3"; #expect(store.filteredEntries.count == 1)
        store.query = "missing"; #expect(store.filteredEntries.isEmpty)
        let hiddenCopy = store.copy(id)
        #expect(!hiddenCopy && writer.writes.isEmpty)
        // Output failures are exercised on a visible target; filtered-out entries must never reach the writer.
        store.query = "ENTRY 3"
        writer.result = .failed; store.copy(id); #expect(store.message?.contains("可能已清空") == true)
        writer.result = .changed; store.copy(id); #expect(store.message?.contains("其他应用") == true)
        #expect(writer.writes.count == 2)
        #expect(store.entries.count == 2)
        store.selectedID = id; await store.delete(id); #expect(store.selectedID == nil)
        #expect(store.entries.count == 1)
    }
    @Test func exactSelfGenerationDoesNotSuppressExternalCopy() async {
        let source = MemoryClipboardSource(); let writer = MemoryClipboardWriter(); let store = ClipboardController(source: source, writer: writer)
        await store.enable()
        source.value = .init(generation: 1, items: [.text("original")], application: "source.app"); await store.refresh()
        store.copy(store.entries[0].id)
        let marker = writer.markers[0]
        source.value = .init(generation: 10, items: [.text("self")], application: "source.app", marker: marker); await store.refresh()
        #expect(store.entries.count == 1)
        source.value = .init(generation: 11, items: [.text("external")], application: "source.app", marker: marker); await store.refresh()
        #expect(store.entries.first?.plainText == "external")
    }
    @Test func generationChangesDuringReadAreRejected() async {
        let source = MemoryClipboardSource(); let store = ClipboardController(source: source, writer: MemoryClipboardWriter())
        await store.enable()
        source.value = .init(generation: 1, items: [.text("raced")], application: "source.app")
        source.afterRead = { source.value = .init(generation: 2, items: [.text("later")], application: "source.app") }
        await store.refresh(); #expect(store.entries.isEmpty)
        source.afterRead = nil; await store.refresh(); #expect(store.entries.first?.plainText == "later")
    }
    @Test func totalBudgetEvictsHistoryButNeverAFavorite() async {
        let source = MemoryClipboardSource(); let store = ClipboardController(source: source, writer: MemoryClipboardWriter())
        await store.enable()
        let body = String(repeating: "x", count: ClipboardPolicy.itemBytes - 10)
        for generation in 1...10 {
            source.value = .init(generation: generation, items: [.text("\(generation)" + body)], application: "source.app")
            await store.refresh()
            if generation == 1 { await store.toggleFavorite(store.entries[0].id) }
        }
        let history = store.entries.filter { !$0.favorite }
        #expect(history.count == 8)
        #expect(history.reduce(0, { $0 + $1.byteCount }) <= ClipboardPolicy.totalBytes)
        #expect(store.entries.filter(\.favorite).count == 1, "A favorite is saved on purpose and is not evicted by the history budget")
    }
}

@Suite("Clipboard Favorites") @MainActor struct ClipboardFavoritesTests {
    private func directory() -> URL { URL(fileURLWithPath: "/private/tmp").appendingPathComponent("traylet-favorites-" + UUID().uuidString) }
    private func controller(_ root: URL, source: MemoryClipboardSource, clock: @escaping () -> Date = Date.init) -> ClipboardController {
        ClipboardController(source: source, writer: MemoryClipboardWriter(), archive: V2ClipboardArchive(directory: root), clock: clock)
    }
    private func copy(_ text: String, generation: Int, into store: ClipboardController, source: MemoryClipboardSource) async {
        source.value = .init(generation: generation, items: [.text(text)], application: "source.app"); await store.refresh()
    }

    @Test func favoriteAndHistorySurviveRestart() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = MemoryClipboardSource(); let first = controller(root, source: source)
        await first.enable()
        await copy("keep me", generation: 1, into: first, source: source)
        await copy("plain history", generation: 2, into: first, source: source)
        await first.toggleFavorite(first.entries.first { $0.plainText == "keep me" }!.id)
        await first.shutdown()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("favorites.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("archive.json").path))
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("favorites.json").path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let second = controller(root, source: MemoryClipboardSource())
        await second.enable()
        #expect(second.entries.map(\.plainText) == ["keep me", "plain history"])
        #expect(second.entries.first?.favorite == true)
    }

    @Test func retentionAndCountNeverRemoveFavoritesButRemoveHistory() async {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = MemoryClipboardSource(); let store = controller(root, source: source, clock: { now })
        var settings = ClipboardSettings(); settings.maximumCount = 1; settings.retentionDays = 1
        await store.updateSettings(settings); await store.enable()
        await copy("favorite", generation: 1, into: store, source: source)
        await store.toggleFavorite(store.entries[0].id)
        await copy("older", generation: 2, into: store, source: source)
        await copy("newer", generation: 3, into: store, source: source)
        #expect(Set(store.entries.compactMap(\.plainText)) == ["favorite", "newer"], "count limit removes history only")
        now.addTimeInterval(3 * 86_400)
        await store.refresh()
        #expect(store.entries.compactMap(\.plainText) == ["favorite"], "retention removes history only")
    }

    @Test func clearKeepsFavoritesAndDeleteAllFavoritesRemovesTheFile() async {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = MemoryClipboardSource(); let store = controller(root, source: source)
        await store.enable()
        await copy("fav", generation: 1, into: store, source: source)
        await copy("other", generation: 2, into: store, source: source)
        await store.toggleFavorite(store.entries.first { $0.plainText == "fav" }!.id)
        await store.clear()
        #expect(store.entries.compactMap(\.plainText) == ["fav"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("favorites.json").path))
        await store.shutdown()
        #expect(store.entries.isEmpty)
        await store.enable()
        #expect(store.entries.compactMap(\.plainText) == ["fav"], "favorites return after restarting")
        await store.deleteAllFavorites()
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("favorites.json").path))
    }

    @Test func unfavoritingAndDeletingUpdateTheSavedFile() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = MemoryClipboardSource(); let store = controller(root, source: source)
        await store.enable()
        await copy("one", generation: 1, into: store, source: source)
        await copy("two", generation: 2, into: store, source: source)
        for entry in store.entries { await store.toggleFavorite(entry.id) }
        let archive = V2ClipboardArchive(directory: root)
        #expect(try await archive.loadFavorites().count == 2)
        await store.toggleFavorite(store.entries.first { $0.plainText == "one" }!.id)
        #expect(try await archive.loadFavorites().compactMap(\.plainText) == ["two"])
        await store.delete(store.entries.first { $0.plainText == "two" }!.id)
        #expect(try await archive.loadFavorites().isEmpty)
    }

    @Test func favoritesAreCappedAndADamagedFileIsQuarantined() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appendingPathComponent("favorites.json"))
        let source = MemoryClipboardSource(); let store = controller(root, source: source)
        await store.enable()
        #expect(store.message?.contains("收藏文件无法读取") == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("favorites.json").path))
        await copy("after damage", generation: 1, into: store, source: source)
        await store.toggleFavorite(store.entries[0].id)
        #expect(try await V2ClipboardArchive(directory: root).loadFavorites().count == 1)
    }
}

@Suite("Clipboard Double Click") @MainActor struct ClipboardDoubleClickTests {
    @Test func copyReportsSuccessSoTheWindowClosesOnlyWhenTheCopyWorked() async {
        let source = MemoryClipboardSource(); let writer = MemoryClipboardWriter(); let store = ClipboardController(source: source, writer: writer)
        await store.enable()
        source.value = .init(generation: 1, items: [.text("entry")], application: "source.app"); await store.refresh()
        let id = store.entries[0].id
        writer.result = .copied(generation: 5); #expect(store.copy(id))
        writer.result = .failed; #expect(!store.copy(id))
        writer.result = .changed; #expect(!store.copy(id))
        #expect(!store.copy(UUID()))
    }
}
