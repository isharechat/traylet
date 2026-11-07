import Foundation
import Testing
@testable import TrayletApp

@Suite("Clipboard Favorite Ordering") @MainActor struct ClipboardFavoriteOrderingTests {
    @Test func favoritesStayAheadOfRecentHistoryInTheOrderTheyWerePinned() async throws {
        let source = MemoryClipboardSource(), clock = ClipboardTestClock()
        let store = ClipboardController(source: source, writer: MemoryClipboardWriter(), clock: { clock.now })
        await store.enable()
        for (index, text) in ["first pin", "second pin", "ordinary"].enumerated() {
            clock.now.addTimeInterval(1)
            source.value = .init(generation: index + 1, items: [.text(text)], application: "synthetic.app")
            await store.refresh()
        }
        let first = try #require(store.entries.first { $0.plainText == "first pin" }?.id)
        let second = try #require(store.entries.first { $0.plainText == "second pin" }?.id)
        await store.toggleFavorite(first); await store.toggleFavorite(second)
        #expect(store.filteredEntries.map(\.plainText) == ["first pin", "second pin", "ordinary"])
        store.favoritesOnly = true
        #expect(store.filteredEntries.map(\.id) == [first, second])
        await store.shutdown()
    }

    @Test
    func restartRestoresFavoritesFileOrderInsteadOfCaptureDate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-favorite-order-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let first = entry("first pin", date: now.addingTimeInterval(-20))
        let second = entry("second pin", date: now.addingTimeInterval(-10))
        let ordinary = entry("ordinary", date: now, favorite: false)
        let seed = V2ClipboardArchive(directory: directory)
        try await seed.replaceFavorites([first, second], revision: 1)
        try await seed.replace([ordinary, second, first], revision: 1)
        let source = MemoryClipboardSource()
        let store = ClipboardController(source: source, writer: MemoryClipboardWriter(), archive: V2ClipboardArchive(directory: directory), clock: { now })
        #expect(!store.enabled && store.entries.isEmpty && source.reads == 0)
        await store.enable()
        #expect(store.filteredEntries == [first, second, ordinary])
        #expect(source.reads == 0)
        await store.shutdown()
    }

    private func entry(_ text: String, date: Date, favorite: Bool = true) -> ClipboardEntry {
        let items: [ClipboardContent] = [.text(text)]
        return .init(id: UUID(), digest: ClipboardPolicy.digest(items), items: items, capturedAt: date, favorite: favorite, application: "synthetic.app")
    }

    @Test func manualOrderPreservesOriginalEntriesSelectionAndSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-favorite-move-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let richItems = [ClipboardContent(representations: [ClipboardContent.textType: Data("rich original".utf8), "public.rtf": Data("{\\rtf1 original}".utf8)]), .text("second item")]
        let first = ClipboardEntry(id: UUID(), digest: ClipboardPolicy.digest(richItems), items: richItems, capturedAt: now, favorite: true, application: "synthetic.rich")
        let second = entry("second", date: now.addingTimeInterval(1))
        let third = entry("third", date: now.addingTimeInterval(2))
        try await V2ClipboardArchive(directory: directory).replaceFavorites([first, second, third], revision: 1)
        let source = MemoryClipboardSource(), writer = MemoryClipboardWriter()
        let store = ClipboardController(source: source, writer: writer, archive: V2ClipboardArchive(directory: directory), clock: { now })
        await store.enable(); store.favoritesOnly = true; store.selectedID = second.id
        #expect(store.filteredEntries == [first, second, third])
        #expect(await store.reorderFavorites([third.id, first.id, second.id]))
        #expect(store.orderedFavoriteIDs == [third.id, first.id, second.id])
        #expect(store.filteredEntries == [third, first, second])
        #expect(store.selectedID == second.id && source.reads == 0 && writer.writes.isEmpty)
        #expect(try await V2ClipboardArchive(directory: directory).loadFavorites() == [third, first, second])
        await store.shutdown(); await store.enable()
        #expect(store.filteredEntries == [third, first, second])
        await store.shutdown()
    }

    @Test func duplicateRecaptureAndNewHistoryCannotMoveManualPins() async throws {
        let source = MemoryClipboardSource(), clock = ClipboardTestClock()
        let store = ClipboardController(source: source, writer: MemoryClipboardWriter(), clock: { clock.now })
        await store.enable()
        for (index, text) in ["alpha", "beta"].enumerated() {
            source.value = .init(generation: index + 1, items: [.text(text)], application: "synthetic.app")
            clock.now.addTimeInterval(1); await store.refresh()
            await store.toggleFavorite(try #require(store.entries.first { $0.plainText == text }?.id))
        }
        let original = store.entries
        let beta = try #require(original.last)
        clock.now.addTimeInterval(1)
        source.value = .init(generation: 3, items: beta.items, application: "synthetic.other")
        await store.refresh()
        #expect(store.orderedFavoriteIDs == original.map(\.id))
        let recaptured = try #require(store.entries.first { $0.id == beta.id })
        #expect(recaptured.items == beta.items && recaptured.digest == beta.digest)
        #expect(recaptured.capturedAt == clock.now && recaptured.application == "synthetic.other")
        clock.now.addTimeInterval(1)
        source.value = .init(generation: 4, items: [.text("ordinary")], application: "synthetic.app")
        await store.refresh()
        #expect(store.filteredEntries.map(\.plainText) == ["alpha", "beta", "ordinary"])
        await store.toggleFavorite(beta.id)
        #expect(store.filteredEntries.map(\.plainText) == ["alpha", "ordinary", "beta"])
        await store.clear()
        #expect(store.filteredEntries.map(\.plainText) == ["alpha"])
        await store.shutdown()
    }

    @Test func initialAndRepeatedStartupRejectReorderingUntilFavoritesHaveLoaded() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let favorites = [entry("alpha", date: now), entry("beta", date: now)]
        let archive = FavoriteOrderingArchive(favorites)
        let store = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: archive, clock: { now })
        for _ in 0..<2 {
            await archive.suspendLoad()
            let startup = Task { await store.enable() }
            await archive.waitUntilLoading()
            #expect(!(await store.reorderFavorites([])))
            #expect(await archive.writeCount == 0)
            await archive.releaseLoad(); await startup.value
            #expect(store.entries == favorites)
            await store.shutdown()
        }
    }

    @Test func failedSaveKeepsMemoryOrderAndRepeatingThatOrderRetriesSaving() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let favorites = [entry("alpha", date: now), entry("beta", date: now)]
        let archive = FavoriteOrderingArchive(favorites)
        let store = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: archive, clock: { now })
        await store.enable(); store.selectedID = favorites[0].id
        await archive.failWrites()
        let reversed = [favorites[1], favorites[0]]
        #expect(!(await store.reorderFavorites(reversed.map(\.id))))
        #expect(store.entries == reversed && store.selectedID == favorites[0].id)
        #expect(store.message == "收藏保存失败；内存中仍保留。")
        #expect(await archive.favorites == favorites)
        await archive.allowWrites()
        #expect(await store.reorderFavorites(reversed.map(\.id)))
        #expect(await archive.favorites == reversed)
        #expect(await archive.writeCount == 2)
        #expect(await store.reorderFavorites(reversed.map(\.id)))
        #expect(await archive.writeCount == 2)
        await store.shutdown()
    }

    @Test func incompleteDuplicateStaleAndSearchOrdersCannotWriteOrDiscardFavorites() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let favorites = [entry("alpha", date: now), entry("beta", date: now)]
        let archive = FavoriteOrderingArchive(favorites)
        let store = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: archive, clock: { now })
        await store.enable(); store.selectedID = favorites[0].id
        let ids = favorites.map(\.id)
        for invalid in [[ids[0]], [ids[0], ids[0]], [ids[0], UUID()], ids + [UUID()]] {
            #expect(!(await store.reorderFavorites(invalid)))
        }
        store.query = "alpha"
        #expect(store.filteredEntries == [favorites[0]])
        #expect(!(await store.reorderFavorites([ids[1], ids[0]])))
        #expect(!(await store.reorderFavorites([ids[0]])))
        #expect(store.entries == favorites && store.selectedID == ids[0])
        #expect(await archive.favorites == favorites)
        #expect(await archive.writeCount == 0)
        store.query = ""; store.favoritesOnly = true
        #expect(await store.reorderFavorites(ids))
        #expect(await archive.writeCount == 0)
        #expect(await store.reorderFavorites([ids[1], ids[0]]))
        #expect(store.filteredEntries == [favorites[1], favorites[0]])
        await store.delete(ids[0])
        let writesAfterDelete = await archive.writeCount
        #expect(!(await store.reorderFavorites(ids)))
        #expect(store.entries == [favorites[1]])
        #expect(await archive.writeCount == writesAfterDelete)
        await store.shutdown()
    }

    @Test func deleteAllDuringInitialLoadCannotBeUndoneByLateFavoritesOrOrderRequests() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let favorites = [entry("alpha", date: now), entry("beta", date: now)]
        let archive = FavoriteOrderingArchive(favorites)
        let store = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: archive, clock: { now })
        await archive.suspendLoad()
        let startup = Task { await store.enable() }
        await archive.waitUntilLoading()
        #expect(!(await store.reorderFavorites(favorites.map(\.id))))
        await store.deleteAllFavorites()
        await archive.releaseLoad(); await startup.value
        #expect(store.orderedFavoriteIDs.isEmpty && store.entries.isEmpty)
        #expect(await archive.favorites.isEmpty)
        #expect(await store.reorderFavorites([]))
        #expect(await archive.writeCount == 0)
        await store.shutdown()
    }

    @Test func deleteAllWhileOrderSaveIsSuspendedCannotReviveFavorites() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let favorites = [entry("alpha", date: now), entry("beta", date: now)]
        let archive = FavoriteOrderingArchive(favorites)
        let store = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: archive, clock: { now })
        await store.enable(); store.selectedID = favorites[0].id
        await archive.suspendWrite()
        let move = Task { await store.reorderFavorites([favorites[1].id, favorites[0].id]) }
        await archive.waitUntilWriting()
        await store.deleteAllFavorites()
        await archive.releaseWrite()
        #expect(!(await move.value))
        #expect(store.entries.isEmpty && store.selectedID == nil)
        #expect(await archive.favorites.isEmpty)
        await store.shutdown(); await store.enable()
        #expect(store.entries.isEmpty)
        await store.shutdown()
    }

    @Test func deleteAllDuringFullHistoryLoadCannotRestoreItsFavoriteCopies() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let favorite = entry("alpha", date: now)
        let ordinary = entry("ordinary", date: now, favorite: false)
        let archive = FavoriteOrderingArchive([favorite], history: [ordinary, favorite])
        let settings = ClipboardSettings()
        let store = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: archive, settings: settings, clock: { now })
        await archive.suspendBodyLoad()
        let startup = Task { await store.enable() }
        await archive.waitUntilLoading()
        await store.deleteAllFavorites()
        await archive.releaseLoad(); await startup.value
        #expect(store.entries == [ordinary] && store.orderedFavoriteIDs.isEmpty)
        #expect(await archive.favorites.isEmpty)
        #expect(await archive.load() == [ordinary])
        await store.shutdown()
    }

    @Test func failedFavoritesFileLoadKeepsFullHistoryFavoritesAheadOfOrdinaryItems() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let olderPin = entry("older pin", date: now.addingTimeInterval(-20))
        let newerPin = entry("newer pin", date: now.addingTimeInterval(-10))
        let ordinary = entry("ordinary", date: now, favorite: false)
        let archive = FavoriteOrderingArchive([], history: [ordinary, newerPin, olderPin])
        await archive.failFavoritesLoad()
        let settings = ClipboardSettings()
        let store = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: archive, settings: settings, clock: { now })
        await store.enable()
        #expect(store.entries == [newerPin, olderPin, ordinary])
        #expect(store.message?.contains("收藏文件无法读取") == true)
        store.favoritesOnly = true
        #expect(store.filteredEntries == [newerPin, olderPin])
        await store.shutdown()
    }

    @Test(arguments: ["delete", "unfavorite", "favorite"])
    func singleItemChangesDuringFavoriteLoadPreserveUnknownFavoritesAndFinishInitialization(action: String) async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let alpha = entry("alpha", date: now.addingTimeInterval(-3))
        let beta = entry("beta", date: now.addingTimeInterval(-2))
        var charlie = entry("charlie", date: now.addingTimeInterval(-1), favorite: false)
        let unknown = entry("only in favorites file", date: now.addingTimeInterval(-4))
        let archive = FavoriteOrderingArchive([beta, alpha, unknown], history: [charlie, alpha, beta])
        let settings = ClipboardSettings()
        let store = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: archive, settings: settings, clock: { now })
        await archive.suspendLoad()
        let startup = Task { await store.enable() }
        await archive.waitUntilLoading()
        switch action {
        case "delete": await store.delete(alpha.id)
        case "unfavorite": await store.toggleFavorite(alpha.id)
        default: await store.toggleFavorite(charlie.id); charlie.favorite = true
        }
        #expect(await archive.writeCount == 0, "A partial loaded set must not replace unknown saved favorites")
        #expect(await archive.favorites == [beta, alpha, unknown])
        await archive.releaseLoad(); await startup.value
        let expected = action == "favorite" ? [beta, alpha, unknown, charlie] : [beta, unknown]
        #expect(store.entries.filter(\.favorite) == expected)
        #expect(await archive.favorites == expected)
        #expect(await store.reorderFavorites(expected.reversed().map(\.id)))
        #expect(await archive.favorites == Array(expected.reversed()))
        await store.shutdown()
    }

    @Test func failedDeferredSavePreservesUnknownOriginalsAndAllowsCompleteOrderRetry() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let alpha = entry("alpha", date: now)
        let beta = entry("beta", date: now)
        let unknown = entry("only in favorites file", date: now)
        let archive = FavoriteOrderingArchive([alpha, beta, unknown], history: [alpha, beta])
        let settings = ClipboardSettings()
        let store = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: archive, settings: settings, clock: { now })
        await archive.suspendLoad(); await archive.failWrites()
        let startup = Task { await store.enable() }
        await archive.waitUntilLoading()
        await store.delete(alpha.id)
        #expect(await archive.writeCount == 0)
        await archive.releaseLoad(); await startup.value
        #expect(store.entries == [beta, unknown])
        #expect(await archive.favorites == [alpha, beta, unknown])
        #expect(store.message == "收藏保存失败；内存中仍保留。")
        await archive.allowWrites()
        #expect(await store.reorderFavorites([beta.id, unknown.id]))
        #expect(await archive.favorites == [beta, unknown])
        #expect(await archive.writeCount == 2)
        await store.shutdown()
    }

    @Test func deleteAllAfterDeferredMutationDiscardsUnknownFavoritesWithoutLateRevival() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let alpha = entry("alpha", date: now)
        let unknown = entry("only in favorites file", date: now)
        let archive = FavoriteOrderingArchive([alpha, unknown], history: [alpha])
        let settings = ClipboardSettings()
        let store = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: archive, settings: settings, clock: { now })
        await archive.suspendLoad()
        let startup = Task { await store.enable() }
        await archive.waitUntilLoading()
        await store.delete(alpha.id)
        #expect(await archive.writeCount == 0)
        await store.deleteAllFavorites()
        await archive.releaseLoad(); await startup.value
        #expect(store.entries.isEmpty && store.orderedFavoriteIDs.isEmpty)
        #expect(await archive.favorites.isEmpty)
        #expect(await store.reorderFavorites([]))
        #expect(await archive.writeCount == 0)
        await store.shutdown()
    }

    @Test(arguments: ["delete-before", "delete-after", "unfavorite-before", "unfavorite-after"])
    func unreadableFavoritesNeverGetReplacedByPartialMemoryAndRetryKeepsUnknownItems(action: String) async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let alpha = entry("alpha", date: now)
        let beta = entry("beta", date: now)
        let unknown = entry("only in favorites file", date: now)
        let archive = FavoriteOrderingArchive([alpha, beta, unknown], history: [alpha, beta])
        let settings = ClipboardSettings()
        let store = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: archive, settings: settings, clock: { now })
        await archive.suspendLoad()
        let startup = Task { await store.enable() }
        await archive.waitUntilLoading()
        if action.hasSuffix("before") {
            if action.hasPrefix("delete") { await store.delete(alpha.id) }
            else { await store.toggleFavorite(alpha.id) }
        }
        await archive.failFavoritesLoad()
        await archive.releaseLoad(); await startup.value
        if action.hasSuffix("after") {
            if action.hasPrefix("delete") { await store.delete(alpha.id) }
            else { await store.toggleFavorite(alpha.id) }
        }
        #expect(store.entries.filter(\.favorite) == [beta])
        #expect(await archive.favorites == [alpha, beta, unknown])
        #expect(await archive.writeCount == 0)
        #expect(!(await store.reorderFavorites([beta.id])))
        store.stop(); await archive.recoverFavoritesLoad(); await store.enable()
        #expect(store.entries.filter(\.favorite) == [beta, unknown])
        if action.hasPrefix("delete") { #expect(!store.entries.contains { $0.id == alpha.id }) }
        else { #expect(store.entries.first { $0.id == alpha.id }?.favorite == false) }
        #expect(await archive.favorites == [beta, unknown])
        #expect(await store.reorderFavorites([unknown.id, beta.id]))
        await store.shutdown()
    }

    @Test(arguments: ["history", "favorites"])
    func ordinaryClearDuringStartupKeepsIndependentFavoritesAndTheirOrdering(blockedLoad: String) async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let alpha = entry("alpha", date: now)
        let beta = entry("beta", date: now)
        let unknown = entry("only in favorites file", date: now)
        let ordinary = entry("ordinary", date: now, favorite: false)
        let archive = FavoriteOrderingArchive([beta, unknown, alpha], history: [ordinary, alpha, beta])
        let settings = ClipboardSettings()
        let store = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: archive, settings: settings, clock: { now })
        if blockedLoad == "history" { await archive.suspendBodyLoad() }
        else { await archive.suspendLoad() }
        let startup = Task { await store.enable() }
        await archive.waitUntilLoading()
        await store.clear()
        await archive.releaseLoad(); await startup.value
        #expect(store.enabled && store.entries == [beta, unknown, alpha])
        #expect(!(await archive.load()).contains { $0.id == ordinary.id })
        #expect(await store.reorderFavorites([alpha.id, beta.id, unknown.id]))
        #expect(await archive.favorites == [alpha, beta, unknown])
        await store.shutdown()
    }

    @Test(arguments: [false, true])
    func explicitRetryLoadsTheCompleteSetOnceWithoutChangingRecordingOrBaseline(copyWhileLoading: Bool) async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let alpha = entry("alpha", date: now), beta = entry("beta", date: now)
        let unknown = entry("only in favorites file", date: now)
        let source = FavoriteRetryClipboardSource(), writer = MemoryClipboardWriter()
        let archive = FavoriteOrderingArchive([alpha, beta, unknown], history: [alpha, beta])
        let settings = ClipboardSettings()
        let store = ClipboardController(source: source, writer: writer, archive: archive, settings: settings, clock: { now })
        #expect(!store.canRetryFavoritesLoading)
        await store.retryFavoritesLoading()
        #expect(await archive.favoritesLoadCount == 0)
        await archive.failFavoritesLoad(); await store.enable()
        #expect(store.canRetryFavoritesLoading)
        await store.delete(alpha.id)
        let generationReads = source.generationReads
        await archive.recoverFavoritesLoad(); await archive.suspendLoad()
        let retry = Task { await store.retryFavoritesLoading() }
        await archive.waitUntilLoading()
        #expect(!store.canRetryFavoritesLoading)
        await store.retryFavoritesLoading()
        #expect(await archive.favoritesLoadCount == 2)
        #expect(store.enabled)
        if copyWhileLoading { #expect(store.copy(beta.id)) }
        await archive.releaseLoad(); await retry.value
        #expect(!store.canRetryFavoritesLoading)
        #expect(store.message == (copyWhileLoading ? "已复制。" : nil))
        #expect(store.entries == [beta, unknown])
        #expect(await archive.favorites == [beta, unknown])
        #expect(source.generationReads == generationReads && source.bodyReads == 0)
        #expect(writer.writes.count == (copyWhileLoading ? 1 : 0))
        #expect(store.enabled)
        await store.retryFavoritesLoading()
        #expect(await archive.favoritesLoadCount == 2)
        #expect(await store.reorderFavorites([unknown.id, beta.id]))
        await store.shutdown()
    }

    @Test func repeatedReadFailureKeepsRetryAvailableAndUnfavoriteDecisionUntilSuccess() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let alpha = entry("alpha", date: now), beta = entry("beta", date: now)
        let unknown = entry("only in favorites file", date: now)
        let archive = FavoriteOrderingArchive([alpha, beta, unknown], history: [alpha, beta])
        let settings = ClipboardSettings()
        let source = FavoriteRetryClipboardSource()
        let store = ClipboardController(source: source, writer: MemoryClipboardWriter(), archive: archive, settings: settings, clock: { now })
        await archive.failFavoritesLoad(); await store.enable()
        await store.toggleFavorite(alpha.id)
        let generationReads = source.generationReads
        await store.retryFavoritesLoading()
        #expect(store.canRetryFavoritesLoading)
        #expect(await archive.favoritesLoadCount == 2)
        #expect(await archive.writeCount == 0)
        #expect(await archive.favorites == [alpha, beta, unknown])
        await archive.recoverFavoritesLoad(); await store.retryFavoritesLoading()
        #expect(!store.canRetryFavoritesLoading && store.message == nil)
        #expect(store.entries.filter(\.favorite) == [beta, unknown])
        #expect(store.entries.first { $0.id == alpha.id }?.favorite == false)
        #expect(await archive.favorites == [beta, unknown])
        #expect(source.generationReads == generationReads && source.bodyReads == 0)
        await store.shutdown()
    }

    @Test(arguments: ["clear", "shutdown", "deleteAll"])
    func lateRetryRespectsOrdinaryClearShutdownAndExplicitFavoriteDeletion(action: String) async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let alpha = entry("alpha", date: now), unknown = entry("only in favorites file", date: now)
        let ordinary = entry("ordinary", date: now, favorite: false)
        let archive = FavoriteOrderingArchive([alpha, unknown], history: [ordinary, alpha])
        let settings = ClipboardSettings()
        let store = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: archive, settings: settings, clock: { now })
        await archive.failFavoritesLoad(); await store.enable()
        await archive.recoverFavoritesLoad(); await archive.suspendLoad()
        let retry = Task { await store.retryFavoritesLoading() }
        await archive.waitUntilLoading()
        switch action {
        case "clear": await store.clear()
        case "shutdown": await store.shutdown()
        default: await store.deleteAllFavorites()
        }
        await archive.releaseLoad(); await retry.value
        #expect(!store.canRetryFavoritesLoading)
        if action == "clear" {
            #expect(store.entries == [alpha, unknown])
            #expect(await store.reorderFavorites([unknown.id, alpha.id]))
        } else if action == "shutdown" {
            #expect(!store.enabled && store.entries.isEmpty)
            #expect(await archive.favorites == [alpha, unknown])
        } else {
            #expect(store.entries == [ordinary] && store.orderedFavoriteIDs.isEmpty)
            #expect(await archive.favorites.isEmpty)
        }
        let loads = await archive.favoritesLoadCount
        await store.retryFavoritesLoading()
        #expect(await archive.favoritesLoadCount == loads)
        await store.shutdown()
    }

    @Test func quarantinedDamagedFavoritesDoNotOfferAnUnnecessaryReadRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-favorite-retry-damaged-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("synthetic damaged archive".utf8).write(to: directory.appendingPathComponent("favorites.json"))
        let source = FavoriteRetryClipboardSource()
        let store = ClipboardController(source: source, writer: MemoryClipboardWriter(), archive: V2ClipboardArchive(directory: directory))
        await store.enable()
        #expect(!store.canRetryFavoritesLoading)
        #expect(store.message?.contains("已隔离") == true)
        let generationReads = source.generationReads
        await store.retryFavoritesLoading()
        #expect(source.generationReads == generationReads && source.bodyReads == 0)
        #expect(await store.reorderFavorites([]))
        await store.shutdown()
    }
}

@MainActor private final class FavoriteRetryClipboardSource: ClipboardSource {
    private(set) var generationReads = 0
    private(set) var bodyReads = 0
    var generation: Int { generationReads += 1; return 0 }
    func read(expectedGeneration: Int, excluding: Set<String>) -> V2ClipboardSnapshot? { bodyReads += 1; return nil }
}

private actor FavoriteOrderingArchive: V2ClipboardArchiving {
    enum Failure: Error { case write, read }
    private(set) var favorites: [ClipboardEntry]
    private var history: [ClipboardEntry]
    private(set) var writeCount = 0
    private(set) var favoritesLoadCount = 0
    private var loadSuspended = false
    private var bodyLoadSuspended = false
    private var loading = false
    private var loadWaiter: CheckedContinuation<Void, Never>?
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var failure = false
    private var loadFailure = false
    private var writeSuspended = false
    private var writing = false
    private var writeWaiter: CheckedContinuation<Void, Never>?
    private var writeContinuation: CheckedContinuation<Void, Never>?
    private var latestRevision: UInt64 = 0
    init(_ favorites: [ClipboardEntry], history: [ClipboardEntry] = []) { self.favorites = favorites; self.history = history }
    func load() async -> [ClipboardEntry] {
        let snapshot = history
        if bodyLoadSuspended {
            loading = true
            await withCheckedContinuation { loadContinuation = $0; loadWaiter?.resume(); loadWaiter = nil }
        }
        return snapshot
    }
    func replace(_ entries: [ClipboardEntry], revision: UInt64) { history = entries }
    func clear(revision: UInt64) { history = [] }
    func loadSettings() -> ClipboardSettings? { nil }
    func saveSettings(_ settings: ClipboardSettings) {}
    func suspendLoad() { loadSuspended = true; loading = false }
    func suspendBodyLoad() { bodyLoadSuspended = true; loading = false }
    func waitUntilLoading() async { if !loading { await withCheckedContinuation { loadWaiter = $0 } } }
    func releaseLoad() { loadSuspended = false; bodyLoadSuspended = false; loadContinuation?.resume(); loadContinuation = nil }
    func failFavoritesLoad() { loadFailure = true }
    func recoverFavoritesLoad() { loadFailure = false }
    func loadFavorites() async throws -> [ClipboardEntry] {
        favoritesLoadCount += 1
        if loadFailure { throw Failure.read }
        let snapshot = favorites
        if loadSuspended {
            loading = true
            await withCheckedContinuation { loadContinuation = $0; loadWaiter?.resume(); loadWaiter = nil }
        }
        if loadFailure { throw Failure.read }
        return snapshot
    }
    func failWrites() { failure = true }
    func allowWrites() { failure = false }
    func suspendWrite() { writeSuspended = true; writing = false }
    func waitUntilWriting() async { if !writing { await withCheckedContinuation { writeWaiter = $0 } } }
    func releaseWrite() { writeSuspended = false; writeContinuation?.resume(); writeContinuation = nil }
    func replaceFavorites(_ entries: [ClipboardEntry], revision: UInt64) async throws {
        writeCount += 1
        if writeSuspended {
            writing = true
            await withCheckedContinuation { writeContinuation = $0; writeWaiter?.resume(); writeWaiter = nil }
        }
        guard revision > latestRevision else { return }; latestRevision = revision
        if failure { throw Failure.write }
        favorites = entries
    }
    func clearFavorites(revision: UInt64) {
        guard revision > latestRevision else { return }; latestRevision = revision; favorites = []
    }
}
