import Foundation
import Combine

@MainActor final class ClipboardController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var paused = false
    @Published private(set) var ignoringNextCopy = false
    @Published private(set) var entries: [ClipboardEntry] = [] {
        didSet { visibleEntriesCache = nil; if !displays.isEmpty, entries.count < displays.count { let ids = Set(entries.map(\.id)); displays = displays.filter { ids.contains($0.key) } } }
    }
    /// Row text, kind and search text derived once per entry; entry bodies never change after capture.
    private var displays: [UUID: ClipboardDisplay] = [:]
    func display(_ entry: ClipboardEntry) -> ClipboardDisplay {
        if let cached = displays[entry.id] { return cached }
        let value = ClipboardDisplay(entry); displays[entry.id] = value; return value
    }
    @Published private(set) var settings: ClipboardSettings
    @Published var query = "" { didSet { if query != oldValue { visibleEntriesCache = nil; reconcileVisibleSelection() } } }
    @Published var favoritesOnly = false { didSet { if favoritesOnly != oldValue { visibleEntriesCache = nil; reconcileVisibleSelection() } } }
    @Published var selectedID: UUID?
    @Published private(set) var pendingDeletionID: UUID?
    @Published private(set) var message: String?
    @Published private(set) var canRetryFavoritesLoading = false
    private let source: any ClipboardSource
    private let writer: any ClipboardWriting
    private let archive: (any V2ClipboardArchiving)?
    private let clock: () -> Date
    private var baseline = 0
    private var revision: UInt64 = 0
    private var lifecycle: UInt64 = 0
    private var runRevision: UInt64 = 0
    private var settingsRevision: UInt64 = 0
    private var persistenceRevision: UInt64 = 0
    private var favoritesRevision: UInt64 = 0
    private var favoritesLoaded = false
    private var favoritesNeedPersistence = false
    /// Local per-item decisions made before the separate favorites snapshot returns.
    private var pendingFavoriteDigests: Set<String> = []
    private enum BodyState { case unloaded, initialized, explicitlyCleared }
    // An empty view before startup finishes is not an authoritative empty archive.
    private var bodyState: BodyState = .unloaded
    private var pruningNeedsPersistence = false
    private let marker = UUID().uuidString
    private var selfGeneration: Int?
    private var timer: Task<Void, Never>?

    init(source: any ClipboardSource, writer: any ClipboardWriting, archive: (any V2ClipboardArchiving)? = nil,
         settings: ClipboardSettings = .init(), clock: @escaping () -> Date = Date.init) {
        self.source = source; self.writer = writer; self.archive = archive; self.settings = settings; self.clock = clock
        favoritesLoaded = archive == nil
        self.settings.normalize()
    }
    private var visibleEntriesCache: [ClipboardEntry]?
    var filteredEntries: [ClipboardEntry] {
        guard favoritesOnly || !query.isEmpty else { return entries }
        if let visibleEntriesCache { return visibleEntriesCache }
        let visible = entries.filter { (!favoritesOnly || $0.favorite) && (query.isEmpty || display($0).text.localizedCaseInsensitiveContains(query) || $0.application.localizedCaseInsensitiveContains(query)) }
        visibleEntriesCache = visible
        return visible
    }
    var selectedEntry: ClipboardEntry? { filteredEntries.first { $0.id == selectedID } }
    func reconcileVisibleSelection() {
        let visible = filteredEntries
        if !visible.contains(where: { $0.id == selectedID }) { selectedID = visible.first?.id }
    }
    func moveVisibleSelection(by offset: Int) {
        let visible = filteredEntries
        guard !visible.isEmpty else { selectedID = nil; return }
        guard let index = visible.firstIndex(where: { $0.id == selectedID }) else { selectedID = visible.first?.id; return }
        guard offset != 0 else { return }
        selectedID = visible[min(visible.count - 1, max(0, index + (offset < 0 ? -1 : 1)))].id
    }
    func enable(poll: Bool = false) async {
        guard !enabled else { return }
        enabled = true; paused = false; lifecycle &+= 1; runRevision &+= 1
        favoritesLoaded = archive == nil
        canRetryFavoritesLoading = false
        let run = runRevision
        defer { if poll, enabled, run == runRevision { startPolling() } }
        let token = lifecycle
        let persistenceToken = persistenceRevision
        let favoritesToken = favoritesRevision
        baseline = source.generation // Start after the current content; never backfill.
        if settings.saveLocally, let archive {
            do {
                let loaded = try await archive.load()
                guard enabled, token == lifecycle else { return }
                if settings.saveLocally, persistenceToken == persistenceRevision {
                    // Favorite mutations during startup supersede copies in the full-history snapshot.
                    var restored = favoritesToken == favoritesRevision ? loaded : loaded.filter { !$0.favorite }
                    if !pendingFavoriteDigests.isEmpty {
                        restored.removeAll { pendingFavoriteDigests.contains($0.digest) }
                        restored += entries.filter { pendingFavoriteDigests.contains($0.digest) }
                    }
                    // Keep a favorite prefix even if the separate favorites file cannot be read.
                    entries = restored.filter(\.favorite) + restored.filter { !$0.favorite }
                    bodyState = .initialized; prune(); await persist()
                }
            } catch { message = "本机历史无法读取，已隔离或暂停保存。可清空后重新开始。" }
        } else {
            bodyState = .initialized
        }
        await loadFavorites(token: token)
    }
    /// Favorites saved earlier return even when full-history saving is off; they are merged by digest, never duplicated.
    private func loadFavorites(token: UInt64) async {
        guard let archive else { return }
        let version = favoritesRevision
        do {
            let saved = try await archive.loadFavorites()
            guard enabled, token == lifecycle, version == favoritesRevision else { return }
            canRetryFavoritesLoading = false
            if message == "收藏文件无法读取；收藏保存已暂停。" { message = nil }
            var orderedIDs: [UUID] = []
            for var favorite in saved {
                guard !pendingFavoriteDigests.contains(favorite.digest) else { continue }
                favorite.favorite = true
                if let index = entries.firstIndex(where: { $0.digest == favorite.digest }) {
                    entries[index].favorite = true; orderedIDs.append(entries[index].id)
                }
                else { entries.append(favorite); orderedIDs.append(favorite.id) }
            }
            let favorites = entries.filter(\.favorite)
            let byID = Dictionary(uniqueKeysWithValues: favorites.map { ($0.id, $0) })
            let orderedSet = Set(orderedIDs)
            entries = orderedIDs.compactMap { byID[$0] } + favorites.filter { !orderedSet.contains($0.id) }
                + entries.filter { !$0.favorite }.sorted { $0.capturedAt > $1.capturedAt }
            favoritesLoaded = true; pendingFavoriteDigests.removeAll(); prune()
            if favoritesNeedPersistence { await persistFavorites(); await persist() }
        } catch {
            guard enabled, token == lifecycle, version == favoritesRevision else { return }
            if let failure = error as? V2ClipboardArchive.Failure, case .damaged = failure {
                canRetryFavoritesLoading = false
                // The archive has preserved the damaged original separately; a new file is safe.
                message = "收藏文件无法读取，已隔离；新收藏仍会保存。"; favoritesLoaded = true
                pendingFavoriteDigests.removeAll()
                if favoritesNeedPersistence { await persistFavorites(); await persist() }
            } else {
                // A transient/unsafe read gives no authoritative saved set. Keep local decisions for a retry.
                message = "收藏文件无法读取；收藏保存已暂停。"
                canRetryFavoritesLoading = true
            }
        }
    }
    /// Retry only the failed favorites read; recording state and the clipboard baseline stay intact.
    func retryFavoritesLoading() async {
        guard enabled, canRetryFavoritesLoading else { return }
        canRetryFavoritesLoading = false
        await loadFavorites(token: lifecycle)
    }
    private func startPolling() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }
    func pause() { guard enabled else { return }; paused = true; baseline = source.generation }
    func resume() { guard enabled else { return }; baseline = source.generation; paused = false }
    func setIgnoringNextCopy(_ value: Bool) {
        guard enabled || !value else { return }
        if value || ignoringNextCopy { baseline = source.generation }
        ignoringNextCopy = value
    }
    func refresh() async {
        guard enabled else { return }
        prune()
        if pruningNeedsPersistence { await persist() }
        guard enabled, !paused else { return }
        let generation = source.generation
        guard generation != baseline else { return }
        baseline = generation
        // Exact writes returned by our writer do not consume the user's next external exclusion.
        if selfGeneration == generation { selfGeneration = nil; return }
        selfGeneration = nil
        if ignoringNextCopy {
            ignoringNextCopy = false
            message = "已忽略一次复制。"
            return // Do not materialize even a sensitive, excluded or unsupported body.
        }
        guard let snapshot = source.read(expectedGeneration: generation, excluding: settings.excludedApplications, policy: settings.capturePolicy),
              snapshot.generation == generation, source.generation == generation, !snapshot.sensitive,
              !snapshot.application.isEmpty, !settings.excludedApplications.contains(snapshot.application),
              ClipboardPolicy.valid(snapshot.items) else { await persist(); return }
        if message == "已忽略一次复制。" { message = nil }
        let digest = ClipboardPolicy.digest(snapshot.items)
        if let index = entries.firstIndex(where: { $0.digest == digest }) {
            var entry = entries.remove(at: index); entry.capturedAt = clock(); entry.application = snapshot.application
            entries.insert(entry, at: entry.favorite ? index : entries.prefix(while: \.favorite).count)
            if entry.favorite { await persistFavorites() }
        } else {
            entries.insert(ClipboardEntry(id: UUID(), digest: digest, items: snapshot.items, capturedAt: clock(), favorite: false, application: snapshot.application), at: entries.prefix(while: \.favorite).count)
        }
        prune(); await persist()
    }
    func loadPreferences() async {
        guard let archive else { return }
        do { if let value = try await archive.loadSettings(), !enabled, settingsRevision == 0 { settings = value } }
        catch { message = "剪贴板偏好无法读取，使用默认设置（仅内存历史）。" }
    }
    func updateSettings(_ value: ClipboardSettings) async {
        let previouslySaved = settings.saveLocally
        let previousPolicy = settings.capturePolicy
        settingsRevision &+= 1; let settingsToken = settingsRevision
        settings = value; settings.normalize(); prune()
        if enabled, settings.capturePolicy != previousPolicy { baseline = source.generation }
        if previouslySaved != settings.saveLocally { persistenceRevision &+= 1 }
        if let archive { do { try await archive.saveSettings(settings) } catch { message = "偏好保存失败。" } }
        guard settingsToken == settingsRevision else { return }
        if previouslySaved && !settings.saveLocally {
            bodyState = .initialized // Explicitly discarding the archive leaves this memory session authoritative.
            await removeArchive()
        }
        else { await persist() }
    }
    static let favoritesLimit = V2ClipboardArchive.favoritesLimit
    var orderedFavoriteIDs: [UUID] { entries.filter(\.favorite).map(\.id) }
    /// Reorders the complete favorite set. A failed save keeps the intended order in memory.
    @discardableResult func reorderFavorites(_ ids: [UUID]) async -> Bool {
        let current = orderedFavoriteIDs
        guard favoritesLoaded, query.isEmpty, ids.count == current.count, Set(ids).count == ids.count, Set(ids) == Set(current) else { return false }
        if ids == current {
            guard favoritesNeedPersistence else { return true }
            let saved = await persistFavorites()
            return saved && orderedFavoriteIDs == ids
        }
        let favorites = Dictionary(uniqueKeysWithValues: entries.filter(\.favorite).map { ($0.id, $0) })
        entries = ids.compactMap { favorites[$0] } + entries.filter { !$0.favorite }
        let saved = await persistFavorites()
        await persist()
        return saved && orderedFavoriteIDs == ids
    }
    /// Favoriting copies the content to a local file that retention and the history limits never remove.
    func toggleFavorite(_ id: UUID) async {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if !entries[index].favorite {
            let saved = entries.filter(\.favorite)
            guard saved.count < Self.favoritesLimit, saved.reduce(0, { $0 + $1.byteCount }) + entries[index].byteCount <= ClipboardPolicy.totalBytes else {
                message = "收藏已达上限（200 条或 32 MiB），请先取消部分收藏。"; return
            }
        }
        var entry = entries.remove(at: index)
        entry.favorite.toggle()
        if !favoritesLoaded { pendingFavoriteDigests.insert(entry.digest) }
        if entry.favorite {
            // A new pin joins the end of the manually ordered favorites.
            entries.insert(entry, at: entries.filter(\.favorite).count)
        } else {
            let position = entries.firstIndex { !$0.favorite && $0.capturedAt < entry.capturedAt } ?? entries.endIndex
            entries.insert(entry, at: position)
        }
        reconcileVisibleSelection()
        await persistFavorites(); await persist()
    }
    var hasFavorites: Bool { entries.contains(where: \.favorite) }
    func requestDeletion(_ id: UUID) { pendingDeletionID = entries.contains(where: { $0.id == id }) ? id : nil }
    func cancelDeletion() { pendingDeletionID = nil }
    func confirmDeletion() async {
        guard let id = pendingDeletionID else { return }
        pendingDeletionID = nil
        await delete(id)
    }
    func delete(_ id: UUID) async {
        let deleted = entries.first(where: { $0.id == id })
        let wasFavorite = deleted?.favorite == true
        let pendingFavoriteChange = !favoritesLoaded && deleted != nil
        if pendingFavoriteChange, let deleted { pendingFavoriteDigests.insert(deleted.digest) }
        entries.removeAll { $0.id == id }; if selectedID == id { selectedID = nil }
        reconcileVisibleSelection()
        if wasFavorite || pendingFavoriteChange { await persistFavorites() }
        await persist()
    }
    /// Explicit, separately confirmed removal of every saved favorite, including the local file.
    func deleteAllFavorites() async {
        canRetryFavoritesLoading = false
        entries.removeAll(where: \.favorite)
        reconcileVisibleSelection()
        favoritesRevision &+= 1
        let version = favoritesRevision
        favoritesLoaded = true
        pendingFavoriteDigests.removeAll()
        if let archive {
            favoritesNeedPersistence = true
            do {
                try await archive.clearFavorites(revision: version)
                if version == favoritesRevision { favoritesNeedPersistence = false }
            } catch { message = "收藏删除失败，请检查文件权限。" }
        }
        await persist()
    }
    func clear() async {
        persistenceRevision &+= 1; entries = entries.filter(\.favorite); selectedID = nil; selfGeneration = nil
        bodyState = .explicitlyCleared
        pendingDeletionID = nil
        if enabled { baseline = source.generation }
        await removeArchive()
    }
    @discardableResult func copy(_ id: UUID, format: ClipboardCopyFormat = .original) -> Bool {
        prune()
        guard let entry = filteredEntries.first(where: { $0.id == id }), ClipboardPolicy.valid(entry.items) else { return false }
        let output: [ClipboardContent]
        switch format {
        case .original: output = entry.items
        case .plainText:
            guard let text = entry.plainText else { message = "此条目没有可复制的文本。"; return false }
            output = [.text(text)]
            // Joining several items adds separators; recheck the outgoing budget before clearing anything.
            guard ClipboardPolicy.valid(output) else { message = "纯文本超过复制上限。"; return false }
        }
        switch writer.write(output, marker: marker) {
        case .copied(let generation): selfGeneration = generation; message = "已复制。"; return true
        case .changed: message = "剪贴板已被其他应用修改，请重试。"
        case .failed: message = "复制失败，当前剪贴板可能已清空。"
        }
        return false
    }
    func stop() { timer?.cancel(); timer = nil; enabled = false; paused = false; ignoringNextCopy = false; canRetryFavoritesLoading = false; lifecycle &+= 1; runRevision &+= 1 }
    func shutdown() async {
        stop(); let token = lifecycle
        prune(); if settings.saveLocally { await persist() }
        guard token == lifecycle else { return }
        entries = []; selectedID = nil; pendingDeletionID = nil; bodyState = .unloaded
        favoritesLoaded = archive == nil
        favoritesNeedPersistence = false
        pendingFavoriteDigests.removeAll()
    }
    /// Runs on every poll, so it only publishes when something is actually removed; otherwise open views would redraw every tick.
    private func prune() {
        let now = clock()
        let cutoff = now.addingTimeInterval(-Double(settings.retentionDays) * 86400), future = now.addingTimeInterval(60)
        // Bodies are immutable and validated when captured or loaded. Polling only needs metadata.
        // Favorites are saved on purpose and exempt from retention, the count limit and the history size budget.
        var kept = 0, size = 0
        let remaining = entries.filter { entry in
            if entry.favorite { return true }
            guard entry.capturedAt > cutoff, entry.capturedAt <= future else { return false }
            kept += 1; size += entry.byteCount
            return kept <= settings.maximumCount && size <= ClipboardPolicy.totalBytes
        }
        if remaining.count != entries.count { entries = remaining; pruningNeedsPersistence = true }
        reconcileVisibleSelection()
    }
    private func persist() async {
        guard bodyState != .unloaded, settings.saveLocally, let archive else { return }
        revision &+= 1; let version = revision; let snapshot = entries
        do {
            try await archive.replace(snapshot, revision: version)
            if revision == version { pruningNeedsPersistence = false }
        }
        catch { message = "本机保存失败；内存历史仍可使用。" }
    }
    @discardableResult private func persistFavorites() async -> Bool {
        guard let archive else { return true }
        // Until loading finishes this is only a partial set; never overwrite unknown saved favorites.
        guard favoritesLoaded else { favoritesNeedPersistence = true; return false }
        favoritesRevision &+= 1; let version = favoritesRevision
        let snapshot = entries.filter(\.favorite)
        favoritesNeedPersistence = true
        do {
            try await archive.replaceFavorites(snapshot, revision: version)
            if version == favoritesRevision { favoritesNeedPersistence = false; return true }
            return false
        }
        catch { message = "收藏保存失败；内存中仍保留。"; return false }
    }
    private func removeArchive() async {
        guard let archive else { return }; revision &+= 1
        do { try await archive.clear(revision: revision) } catch { message = "本机历史删除失败，请检查文件权限。" }
    }
}
