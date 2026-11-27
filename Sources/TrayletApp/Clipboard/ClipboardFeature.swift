import AppKit
import SwiftUI
import Combine
import ImageIO
import UniformTypeIdentifiers

@MainActor final class ClipboardFeature: ObservableObject {
    static let windowWidth: CGFloat = 380
    static let windowHeight: CGFloat = 500
    static let minimumWidth: CGFloat = 340
    static let minimumHeight: CGFloat = 380
    static let detailWidth: CGFloat = 380
    static let detailHeight: CGFloat = 460
    let controller: ClipboardController
    let imageEditing: ClipboardImageEditing
    let storageDirectory: URL
    var canEditImage: (() -> Bool)?
    var onEditImage: ((ClipboardPreparedImage) -> Bool)?
    var canRecognizeImage: (() -> Bool)?
    var onRecognizeImage: ((ClipboardPreparedImage) -> Bool)?
    private var imageObservations: Set<AnyCancellable> = []
    private let presentWindow: (NSPanel) -> Void
    private let dismissWindow: (NSPanel) -> Void
    private weak var searchField: NSTextField?
    private var wantsSearchFocus = false
    private var panel: NSPanel?
    private var backing: GlassWindowBacking?
    private var dismissal: NSObjectProtocol?
    private var closeObservation: NSObjectProtocol?
    private var mainMoveObservation: NSObjectProtocol?
    private var mainResizeObservation: NSObjectProtocol?
    private var detailPanel: NSPanel?
    private var detailBacking: GlassWindowBacking?
    private var detailHosting: NSHostingView<AnyView>?
    private var detailDismissal: NSObjectProtocol?
    private var detailResignObservation: NSObjectProtocol?
    private var focusObservations: [NSObjectProtocol] = []
    @Published private(set) var isWindowFocused = false
    private(set) var renderedDetailID: UUID?
    private let preferences: Task<Void, Never>
    private var pendingMutations: [UUID: Task<Void, Never>] = [:]
    private var dismissing = false
    private var shuttingDown = false
    init(directory: URL, source: (any ClipboardSource)? = nil, writer: (any ClipboardWriting)? = nil, archive: (any ClipboardArchiving)? = nil, clock: @escaping () -> Date = Date.init,
         imageEditing: ClipboardImageEditing = ClipboardImageEditing(), autoStart: Bool = false,
         presentWindow: @escaping (NSPanel) -> Void = { window in window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) },
         dismissWindow: @escaping (NSPanel) -> Void = { $0.orderOut(nil) }) {
        let controller = ClipboardController(source: source ?? ClipboardNativeSource(), writer: writer ?? ClipboardNativeWriter(), archive: archive ?? ClipboardArchive(directory: directory), clock: clock)
        self.controller = controller
        self.imageEditing = imageEditing
        self.storageDirectory = directory
        self.presentWindow = presentWindow; self.dismissWindow = dismissWindow
        preferences = Task { await controller.loadPreferences() }
        controller.$query.removeDuplicates().dropFirst().sink { [weak imageEditing] _ in imageEditing?.cancel() }.store(in: &imageObservations)
        controller.$favoritesOnly.removeDuplicates().dropFirst().sink { [weak imageEditing] _ in imageEditing?.cancel() }.store(in: &imageObservations)
        controller.$selectedID.removeDuplicates().dropFirst().sink { [weak imageEditing] _ in imageEditing?.cancel() }.store(in: &imageObservations)
        controller.$selectedID.removeDuplicates().dropFirst().sink { [weak self] _ in
            // `@Published` fires during `willSet`, before `selectedID` is stored, so read the new selection on the next actor turn.
            Task { @MainActor [weak self] in self?.syncDetailPanel() }
        }.store(in: &imageObservations)
        controller.$entries.sink { [weak imageEditing] in imageEditing?.validate(entries: $0) }.store(in: &imageObservations)
        // The application records for the whole run with no user on/off or pause; it passes autoStart to begin collecting here.
        if autoStart { Task { await start(poll: true) } }
    }
    /// Starts the run's recording. Recording is always on and needs no per-run confirmation; the
    /// baseline is set after the current content, so nothing already on the clipboard is backfilled.
    func start(poll: Bool = true) async {
        guard !shuttingDown else { return }
        await preferences.value
        guard !shuttingDown, !Task.isCancelled else { return }
        await controller.enable(poll: poll)
    }
    /// Double-click / Return on a row: copy it, and close the window only when the copy really succeeded.
    func copyAndClose(_ id: UUID) {
        if controller.copy(id) { dismiss() }
    }
    func copySelectedAndClose() {
        guard let entry = controller.selectedEntry else { return }
        copyAndClose(entry.id)
    }
    func dismiss() {
        guard !dismissing else { return }
        dismissing = true
        defer { dismissing = false }
        imageEditing.cancel()
        isWindowFocused = false
        hideDetailPanel()
        if let panel { dismissWindow(panel) }
    }
    /// Explicit image action, separate from Return/double-click's original-format copy.
    @discardableResult func editImage(_ id: UUID, itemIndex: Int) -> Task<Void, Never>? {
        guard !shuttingDown, !imageEditing.isPreparing,
              let entry = controller.filteredEntries.first(where: { $0.id == id }),
              ClipboardImageEditing.imageIndices(in: entry).contains(itemIndex) else { return nil }
        controller.selectedID = id
        guard canEditImage?() == true else { imageEditing.reportUnavailable(); return nil }
        return imageEditing.begin(entry: entry, itemIndex: itemIndex, isCurrent: { [weak self] in
            guard let self, !self.shuttingDown, let current = self.controller.selectedEntry else { return false }
            return current.id == id && current.digest == entry.digest
        }, open: { [weak self] result in
            guard let self, !self.shuttingDown, self.onEditImage?(result) == true else { return false }
            self.dismiss(); return true
        })
    }
    @discardableResult func recognizeImage(_ id: UUID, itemIndex: Int) -> Task<Void, Never>? {
        guard !shuttingDown, !imageEditing.isPreparing,
              let entry = controller.filteredEntries.first(where: { $0.id == id }),
              ClipboardImageEditing.imageIndices(in: entry).contains(itemIndex) else { return nil }
        controller.selectedID = id
        guard canRecognizeImage?() == true else { imageEditing.reportUnavailable(); return nil }
        return imageEditing.begin(entry: entry, itemIndex: itemIndex, isCurrent: { [weak self] in
            guard let self, !self.shuttingDown, let current = self.controller.selectedEntry else { return false }
            return current.id == id && current.digest == entry.digest
        }, open: { [weak self] result in
            guard let self, !self.shuttingDown, self.onRecognizeImage?(result) == true else { return false }
            self.dismiss(); return true
        })
    }
    @discardableResult func moveFavorites(from offsets: IndexSet, to destination: Int) async -> Bool {
        var ids = controller.orderedFavoriteIDs
        guard !shuttingDown, controller.query.isEmpty, !offsets.isEmpty, offsets.allSatisfy(ids.indices.contains),
              destination >= 0, destination <= ids.count else { return false }
        ids.move(fromOffsets: offsets, toOffset: destination)
        return await controller.reorderFavorites(ids)
    }
    func runMutation(_ operation: @escaping @MainActor () async -> Void) {
        guard !shuttingDown else { return }
        let id = UUID()
        pendingMutations[id] = Task { @MainActor [weak self] in
            defer { self?.pendingMutations.removeValue(forKey: id) }
            await operation()
        }
    }
    @discardableResult func queueFavoriteMove(from offsets: IndexSet, to destination: Int) -> Task<Bool, Never> {
        // AppKit supplies offsets for this exact visible prefix, before the async action is queued.
        let expectedOrder = controller.orderedFavoriteIDs
        let id = UUID()
        let task = Task { [weak self] in
            defer { self?.pendingMutations.removeValue(forKey: id) }
            guard let self, self.controller.orderedFavoriteIDs == expectedOrder else { return false }
            return await self.moveFavorites(from: offsets, to: destination)
        }
        pendingMutations[id] = Task { _ = await task.value }
        return task
    }
    func present() {
        wantsSearchFocus = true
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = L("剪贴板"); window.minSize = NSSize(width: Self.minimumWidth, height: Self.minimumHeight)
            window.isReleasedWhenClosed = false
            backing = GlassWindowBacking(window: window, content: NSHostingView(rootView: ClipboardFeatureView(feature: self)))
            window.center(); panel = window
            dismissal = FloatingWindow.hideOnResignKey(window) { [weak self] in self?.dismiss() }
            closeObservation = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.shuttingDown else { return }
                    self.dismiss()
                }
            }
            mainMoveObservation = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.positionDetailPanel() }
            }
            mainResizeObservation = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.positionDetailPanel() }
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                focusObservations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshWindowFocus() }
                })
            }
        }
        refreshTitle()
        ensureDetailPanel()
        if let panel {
            panel.contentView?.layoutSubtreeIfNeeded()
            presentWindow(panel)
            isWindowFocused = true
            focusSearchIfNeeded()
            syncDetailPanel()
        }
    }
    func attachSearchField(_ field: NSTextField) {
        searchField = field
        focusSearchIfNeeded()
    }
    private func focusSearchIfNeeded() {
        guard wantsSearchFocus, let panel, let searchField, searchField.window === panel else { return }
        if panel.makeFirstResponder(searchField) { wantsSearchFocus = false }
    }
    /// Builds the companion popup once with the same glass backing as the list window, without titlebar buttons.
    private func ensureDetailPanel() {
        guard detailPanel == nil, panel != nil else { return }
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.detailWidth, height: Self.detailHeight), styleMask: [.titled, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = L("剪贴板详情")
        window.minSize = NSSize(width: Self.minimumWidth, height: Self.minimumHeight)
        window.becomesKeyOnlyIfNeeded = true
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(ClipboardDetailView(feature: self)))
        detailBacking = GlassWindowBacking(window: window, content: hosting)
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        hosting.layoutSubtreeIfNeeded()
        detailHosting = hosting
        detailPanel = window
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            focusObservations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWindowFocus() }
            })
        }
        detailDismissal = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.shuttingDown else { return }
                self.dismiss()
            }
        }
        detailResignObservation = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let detailPanel = self.detailPanel, let mainPanel = self.panel,
                          detailPanel.isVisible, !self.shuttingDown else { return }
                    let keepOpen = NSApp.keyWindow === mainPanel || FloatingWindow.ownsKeyPopup(of: mainPanel)
                    if !keepOpen, mainPanel.isVisible, detailPanel.attachedSheet == nil, NSApp.modalWindow == nil {
                        self.dismiss()
                    }
                }
            }
        }
    }
    /// The full content lives in a companion popup instead of the list window.
    private func syncDetailPanel() {
        guard !shuttingDown, let entry = controller.selectedEntry else {
            renderedDetailID = nil
            hideDetailPanel()
            return
        }
        ensureDetailPanel()
        // Re-render synchronously for the current selection before the popup appears, so it can never show an empty or stale frame.
        detailHosting?.rootView = AnyView(ClipboardDetailView(feature: self).id(entry.id))
        renderedDetailID = entry.id
        detailHosting?.layoutSubtreeIfNeeded()
        positionDetailPanel()
        if let panel, let detailPanel, detailPanel.parent !== panel {
            panel.addChildWindow(detailPanel, ordered: .above)
        }
        detailPanel?.orderFront(nil)
    }
    private func hideDetailPanel() {
        detailPanel?.orderOut(nil)
    }
    private func refreshWindowFocus() {
        isWindowFocused = (panel?.isKeyWindow == true) || (detailPanel?.isKeyWindow == true)
    }
    /// Places the detail popup to the right of the list window, falling back to the left when the right edge has no room.
    private func positionDetailPanel() {
        guard let panel, let detailPanel else { return }
        let gap: CGFloat = 8
        let size = detailPanel.frame.size
        let mainFrame = panel.frame
        var origin = NSPoint(x: mainFrame.maxX + gap, y: mainFrame.midY - size.height / 2)
        if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if mainFrame.maxX + gap + size.width > visible.maxX {
                origin.x = mainFrame.minX - gap - size.width
                if origin.x < visible.minX { origin.x = visible.minX }
            }
            origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        }
        detailPanel.setFrameOrigin(origin)
    }
    var showsDetail: Bool { controller.selectedEntry != nil }
    var isDetailPanelBuilt: Bool { detailPanel != nil }
    var detailPanelForTesting: NSPanel? { detailPanel }
    var storagePath: String {
        storageDirectory.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
    func refreshTitle() {
        panel?.title = L("剪贴板")
        detailPanel?.title = L("剪贴板详情")
    }
    func shutdown() { shuttingDown = true; imageEditing.cancel(); controller.stop(); detailPanel?.close(); panel?.close(); Task { await awaitPendingMutations(); await controller.shutdown() } }
    func shutdownAndWait() async {
        shuttingDown = true; imageEditing.cancel(); controller.stop(); detailPanel?.close(); panel?.close()
        await awaitPendingMutations()
        await controller.shutdown()
    }
    private func awaitPendingMutations() async {
        while !pendingMutations.isEmpty {
            let tasks = Array(pendingMutations.values)
            for task in tasks { await task.value }
        }
    }
}

extension ClipboardKind {
    @MainActor var title: String { switch self { case .text: L("文本"); case .link: L("链接"); case .image: L("图片") } }
}

@MainActor struct ClipboardFeatureView: View {
    @ObservedObject private var feature: ClipboardFeature
    @ObservedObject private var localization = Localization.shared
    @ObservedObject private var controller: ClipboardController
    @ObservedObject private var imageEditing: ClipboardImageEditing
    @State private var confirmClear = false
    @State private var confirmDeleteFavorites = false
    @State private var confirmDelete = false
    init(feature: ClipboardFeature) { self.feature = feature; controller = feature.controller; imageEditing = feature.imageEditing }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if imageEditing.isPreparing {
                    ProgressView().controlSize(.small).accessibilityLabel(L("正在准备图片…"))
                    Button(L("取消")) { imageEditing.cancel() }
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
                    ClipboardSearchField(feature: feature)
                    if !controller.query.isEmpty {
                        Button { controller.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain).help(L("清除搜索")).accessibilityLabel(L("清除搜索"))
                    }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .v2GlassBackground(in: Capsule(), interactive: true)
                Button {
                    controller.favoritesOnly.toggle()
                } label: {
                    Image(systemName: controller.favoritesOnly ? "star.fill" : "star")
                        .foregroundStyle(controller.favoritesOnly ? Color.yellow : Color.secondary)
                        .frame(width: Design.iconButton, height: Design.iconButton)
                        .background(controller.favoritesOnly ? Color.yellow.opacity(0.16) : Color.clear, in: Circle())
                        .v2GlassBackground(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain).help(L("仅收藏")).accessibilityLabel(L("仅收藏"))
                if controller.ignoringNextCopy {
                    Button { controller.setIgnoringNextCopy(false) } label: {
                        Image(systemName: "eye.slash.fill")
                            .frame(width: Design.iconButton, height: Design.iconButton)
                            .v2GlassBackground(in: Circle(), interactive: true)
                    }
                        .buttonStyle(.plain).help(L("取消忽略下一次复制")).accessibilityLabel(L("取消忽略下一次复制"))
                }
                Menu {
                    Toggle(L("忽略下一次复制"), isOn: Binding(get: { controller.ignoringNextCopy }, set: controller.setIgnoringNextCopy))
                        .disabled(!controller.enabled)
                    if controller.canRetryFavoritesLoading {
                        Button(L("重试加载收藏")) { Task { await controller.retryFavoritesLoading() } }
                    }
                    if let entry = controller.selectedEntry, !controller.display(entry).text.isEmpty {
                        Button(L("复制纯文本")) { controller.copy(entry.id, format: .plainText) }
                    }
                    if let entry = controller.selectedEntry {
                        imageEditActions(entry)
                        imageRecognitionActions(entry)
                        if entry.favorite { favoriteMoveActions(entry) }
                    }
                    Divider()
                    Button(L("清空"), role: .destructive) { confirmClear = true }
                    Button(L("删除所有收藏…"), role: .destructive) { confirmDeleteFavorites = true }.disabled(!controller.hasFavorites)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: Design.iconButton, height: Design.iconButton)
                        .v2GlassBackground(in: Circle(), interactive: true)
                }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("更多")).accessibilityLabel(L("更多"))
            }.padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            if let message = activeMessage {
                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            historyList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                Text(String(format: L("%d / %d 条 · 保留 %d 天"), controller.entries.count, controller.settings.maximumCount, controller.settings.retentionDays))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Text(L("↵ 复制"))
                    Text(L("Esc 关闭"))
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .environment(\.controlActiveState, feature.isWindowFocused ? .key : .inactive)
        .onExitCommand { feature.dismiss() }
        .background {
            Button {
                if let entry = controller.selectedEntry { controller.copy(entry.id) }
            } label: { EmptyView() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onChange(of: localization.languageCode) { _, _ in feature.refreshTitle() }
        .alert(L("删除所有收藏？"), isPresented: $confirmDeleteFavorites) {
            Button(L("取消"), role: .cancel) {}
            Button(L("删除所有收藏"), role: .destructive) { feature.runMutation { await controller.deleteAllFavorites() } }
        } message: { Text(L("将删除内存和本机保存的全部收藏内容，不修改当前系统剪贴板。")) }
        .alert(L("清空剪贴板历史？"), isPresented: $confirmClear) {
            Button(L("取消"), role: .cancel) {}
            Button(L("清空"), role: .destructive) { feature.runMutation { await controller.clear() } }
        } message: { Text(L("将清空非收藏的历史；收藏保留在本机。不修改当前系统剪贴板。")) }
        .alert(L("删除这条剪贴板历史？"), isPresented: $confirmDelete) {
            Button(L("取消"), role: .cancel) { controller.cancelDeletion() }
            Button(L("删除"), role: .destructive) { feature.runMutation { await controller.confirmDeletion() } }
        } message: { Text(L("同时删除本机保存的这一项（含收藏），不修改当前系统剪贴板。")) }
    }
    /// Every row has the same height; long text is truncated to one line with an ellipsis.
    private var historyList: some View {
        let favoriteEntries = controller.filteredEntries.filter(\.favorite)
        let recentEntries = controller.filteredEntries.filter { !$0.favorite }
        return List(selection: $controller.selectedID) {
            if controller.favoritesOnly {
                ForEach(favoriteEntries) { entry in historyRow(entry) }
                    .onMove { offsets, destination in feature.queueFavoriteMove(from: offsets, to: destination) }
            } else if !favoriteEntries.isEmpty && !recentEntries.isEmpty {
                Section {
                    ForEach(favoriteEntries) { entry in
                        historyRow(entry)
                            .moveDisabled(!controller.query.isEmpty)
                    }
                    .onMove { offsets, destination in feature.queueFavoriteMove(from: offsets, to: destination) }
                } header: {
                    sectionHeader(title: L("收藏"), count: favoriteEntries.count)
                }
                Section {
                    ForEach(recentEntries) { entry in historyRow(entry) }
                } header: {
                    sectionHeader(title: L("最近"), count: recentEntries.count)
                }
            } else if !favoriteEntries.isEmpty {
                ForEach(favoriteEntries) { entry in
                    historyRow(entry)
                        .moveDisabled(!controller.query.isEmpty)
                }
                .onMove { offsets, destination in feature.queueFavoriteMove(from: offsets, to: destination) }
            } else {
                ForEach(recentEntries) { entry in historyRow(entry) }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight, 34)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let entry = controller.entries.first(where: { $0.id == id }) {
                Button(L("复制")) { controller.copy(id) }
                Button(L("复制纯文本")) { controller.copy(id, format: .plainText) }.disabled(controller.display(entry).text.isEmpty)
                Button(L(entry.favorite ? "取消收藏" : "收藏")) { feature.runMutation { await controller.toggleFavorite(id) } }
                imageEditActions(entry)
                imageRecognitionActions(entry)
                if entry.favorite { favoriteMoveActions(entry) }
                Button(L("删除"), role: .destructive) { requestDeletion(id) }
            }
        } primaryAction: { ids in if let id = ids.first { feature.copyAndClose(id) } }
        .overlay {
            if controller.filteredEntries.isEmpty {
                VStack(spacing: 8) {
                    if !controller.query.isEmpty || controller.favoritesOnly {
                        Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(.tertiary)
                        Text(L("暂无匹配历史")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        Button(L("清除筛选")) {
                            controller.query = ""
                            controller.favoritesOnly = false
                        }
                        .controlSize(.small)
                    } else {
                        Image(systemName: "clipboard").font(.system(size: 24)).foregroundStyle(.tertiary)
                        Text(L("剪贴板历史为空")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        Text(L("复制文字或图片后会自动出现在这里")).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding()
            }
        }
    }
    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text("· \(count)").monospacedDigit().foregroundStyle(.tertiary)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
    }
    private func historyRow(_ entry: ClipboardEntry) -> some View {
        let display = controller.display(entry)
        let line = display.line ?? L("图片")
        return ClipboardHistoryRow(
            entry: entry,
            kind: display.kind,
            line: line,
            onCopy: { controller.copy(entry.id) },
            onToggleFavorite: { feature.runMutation { await controller.toggleFavorite(entry.id) } }
        )
        .tag(entry.id)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(display.kind.title + ", " + line)
    }
    private var activeMessage: String? {
        if let message = imageEditing.message { return L(message) }
        if let message = controller.message { return L(message) }
        return nil
    }
    private func requestDeletion(_ id: UUID) {
        controller.requestDeletion(id)
        confirmDelete = controller.pendingDeletionID != nil
    }
    @ViewBuilder private func imageEditActions(_ entry: ClipboardEntry, compact: Bool = false) -> some View {
        let indices = ClipboardImageEditing.imageIndices(in: entry)
        if indices.count == 1, let index = indices.first {
            Button { feature.editImage(entry.id, itemIndex: index) } label: {
                if compact { Image(systemName: "pencil") } else { Text(L("编辑图片")) }
            }.disabled(imageEditing.isPreparing).help(L("编辑副本，保留历史原件")).accessibilityLabel(L("编辑图片"))
        } else if !indices.isEmpty {
            Menu(L("编辑图片")) {
                ForEach(Array(indices.enumerated()), id: \.element) { offset, index in
                    Button(String(format: L("图片 %d"), offset + 1)) { feature.editImage(entry.id, itemIndex: index) }
                }
            }.disabled(imageEditing.isPreparing)
        }
    }
    @ViewBuilder private func imageRecognitionActions(_ entry: ClipboardEntry) -> some View {
        let indices = ClipboardImageEditing.imageIndices(in: entry)
        if indices.count == 1, let index = indices.first {
            Button(L("识别文字")) { feature.recognizeImage(entry.id, itemIndex: index) }
                .disabled(imageEditing.isPreparing).help(L("本机识别，校正后再翻译"))
        } else if !indices.isEmpty {
            Menu(L("识别文字")) {
                ForEach(Array(indices.enumerated()), id: \.element) { offset, index in
                    Button(String(format: L("图片 %d"), offset + 1)) { feature.recognizeImage(entry.id, itemIndex: index) }
                }
            }.disabled(imageEditing.isPreparing)
        }
    }
    @ViewBuilder private func favoriteMoveActions(_ entry: ClipboardEntry) -> some View {
        let ids = controller.orderedFavoriteIDs
        let index = ids.firstIndex(of: entry.id)
        Button(L("收藏上移")) { moveFavorite(entry.id, offset: -1) }
            .disabled(!controller.query.isEmpty || index == nil || index == 0)
        Button(L("收藏下移")) { moveFavorite(entry.id, offset: 1) }
            .disabled(!controller.query.isEmpty || index == nil || index == ids.count - 1)
    }
    private func moveFavorite(_ id: UUID, offset: Int) {
        var ids = controller.orderedFavoriteIDs
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        feature.runMutation { _ = await controller.reorderFavorites(ids) }
    }
}

/// Full clipboard content in a separate popup beside the list window. It shows only the content
/// and its source application; copy/delete/favorite actions stay in the list window.
@MainActor struct ClipboardDetailView: View {
    @ObservedObject private var feature: ClipboardFeature
    @ObservedObject private var controller: ClipboardController
    init(feature: ClipboardFeature) { self.feature = feature; controller = feature.controller }
    var body: some View {
        Group {
            if let entry = controller.selectedEntry {
                let display = controller.display(entry)
                VStack(spacing: 0) {
                    sourceHeader(entry: entry, display: display)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                    Divider()
                    content(entry: entry, display: display)
                    Divider()
                    detailFooter(entry: entry, display: display)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text(L("未选择内容"))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            Button {
                if let entry = controller.selectedEntry { controller.copy(entry.id) }
            } label: { EmptyView() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .environment(\.controlActiveState, feature.isWindowFocused ? .key : .inactive)
        .onExitCommand { feature.dismiss() }
    }
    private func sourceHeader(entry: ClipboardEntry, display: ClipboardDisplay) -> some View {
        let tint: Color = display.kind == .image ? .indigo : (display.kind == .link ? .teal : .accentColor)
        return HStack(spacing: 10) {
            Image(systemName: display.kind.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Design.Radius.badge))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.application).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    StatusPill(text: display.kind.title, tint: tint)
                }
                Text(entry.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            HStack(spacing: 2) {
                let imageIndices = ClipboardImageEditing.imageIndices(in: entry)
                if imageIndices.count == 1, let index = imageIndices.first {
                    WorkspaceIconButton(
                        symbol: "pencil",
                        label: "编辑图片",
                        help: "编辑副本，保留历史原件",
                        size: 26,
                        iconSize: 12,
                        disabled: feature.imageEditing.isPreparing
                    ) {
                        feature.editImage(entry.id, itemIndex: index)
                    }
                    WorkspaceIconButton(
                        symbol: "text.viewfinder",
                        label: "识别文字",
                        help: "本机识别，校正后再翻译",
                        size: 26,
                        iconSize: 12,
                        disabled: feature.imageEditing.isPreparing
                    ) {
                        feature.recognizeImage(entry.id, itemIndex: index)
                    }
                }
                WorkspaceIconButton(
                    symbol: entry.favorite ? "star.fill" : "star",
                    label: entry.favorite ? "取消收藏" : "收藏",
                    tint: entry.favorite ? .yellow : nil,
                    size: 26,
                    iconSize: 12
                ) {
                    feature.runMutation { await controller.toggleFavorite(entry.id) }
                }
                CopyIconButton(label: "复制", size: 26, iconSize: 12) {
                    controller.copy(entry.id)
                }
            }
        }
    }
    @ViewBuilder private func content(entry: ClipboardEntry, display: ClipboardDisplay) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                if entry.imageData != nil { ClipboardPreviewImage(entry: entry) }
                if !display.text.isEmpty { ClipboardPreviewText(entryID: entry.id, text: display.text, singleLine: display.singleLine) }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func detailFooter(entry: ClipboardEntry, display: ClipboardDisplay) -> some View {
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file)
        return HStack(spacing: 10) {
            Text(sizeText)
            if !display.text.isEmpty {
                let lineCount = max(1, display.text.split(separator: "\n", omittingEmptySubsequences: false).count)
                Text("·")
                Text(String(format: L("%d 字符"), display.text.count))
                Text("·")
                Text(String(format: L("%d 行"), lineCount))
            }
            Spacer(minLength: 0)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 7)
    }
}

@MainActor struct ClipboardFeatureSettingsView: View {
    let feature: ClipboardFeature
    @ObservedObject private var localization = Localization.shared
    @ObservedObject private var controller: ClipboardController
    @State private var exclusions = ""
    init(feature: ClipboardFeature) { self.feature = feature; controller = feature.controller }
    var body: some View {
        Form {
            Section {
                LabeledContent(L("最大数量")) {
                    ClipboardLimitField("最大数量", unit: "条", value: setting(\.maximumCount), range: 1...1000)
                }
                LabeledContent(L("保留期限")) {
                    ClipboardLimitField("保留期限", unit: "天", value: setting(\.retentionDays), range: 1...30)
                }
            }
            Section {
                Toggle(L("文字与富文本"), isOn: captureSetting(\.captureText))
                Toggle(L("图片"), isOn: captureSetting(\.captureImages))
            } header: {
                Text(L("记录类型"))
            } footer: {
                if !controller.settings.capturePolicy.hasEnabledType {
                    Text(L("未选择类型，不记录新内容。"))
                }
            }
            .help(L("混合复制须全部允许，保留原格式。富文本可含内嵌内容，图片可附带文字。"))
            Section(L("本机保存")) {
                LabeledContent(L("保存路径")) {
                    HStack(spacing: 8) {
                        Text(feature.storagePath).font(.caption.monospaced()).textSelection(.enabled)
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button(L("在访达中显示")) {
                            NSWorkspace.shared.activateFileViewerSelecting([feature.storageDirectory])
                        }
                        .controlSize(.small)
                    }
                }
            }
            Section(L("排除应用")) {
                let excluded = controller.settings.excludedApplications.sorted()
                if !excluded.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(excluded, id: \.self) { bundleID in
                            HStack(spacing: 4) {
                                Text(bundleID)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Button {
                                    update { $0.excludedApplications.remove(bundleID) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(L("移除"))
                                .accessibilityLabel(L("移除") + " " + bundleID)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(nsColor: .quaternarySystemFill), in: Capsule())
                        }
                    }
                    .padding(.vertical, 2)
                }
                HStack(spacing: 6) {
                    TextField(L("排除应用"), text: $exclusions, prompt: Text(L("输入 Bundle ID"))).labelsHidden()
                        .onSubmit { addExclusions() }
                    Button(L("添加")) { addExclusions() }
                        .disabled(exclusions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(L("选择应用…")) { chooseExcludedApplication() }
                }
            }
            Section {
                HStack {
                    if let message = controller.message { Text(L(message)).foregroundStyle(.secondary) }
                    Spacer()
                    Button(L("打开剪贴板")) { feature.present() }
                }
            }
        }
        .formStyle(.grouped)
    }
    private func setting(_ key: WritableKeyPath<ClipboardSettings, Int>) -> Binding<Int> {
        Binding(get: { controller.settings[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } })
    }
    private func captureSetting(_ key: WritableKeyPath<ClipboardSettings, Bool>) -> Binding<Bool> {
        Binding(get: { controller.settings[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } })
    }
    private func addExclusions() {
        let items = exclusions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !items.isEmpty else { return }
        exclusions = ""
        update { $0.excludedApplications.formUnion(items) }
    }
    private func chooseExcludedApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let bundleIDs = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        guard !bundleIDs.isEmpty else { return }
        update { $0.excludedApplications.formUnion(bundleIDs) }
    }
    private func update(_ change: @escaping (inout ClipboardSettings) -> Void) {
        feature.runMutation { var value = controller.settings; change(&value); await controller.updateSettings(value) }
    }
}

/// Bounds SwiftUI Text layout cost on multi-megabyte entries while Copy still preserves the full original body.
private struct ClipboardPreviewText: View {
    nonisolated static let maximumPreviewCharacters = 32_000
    let entryID: UUID
    let text: String
    let singleLine: Bool
    @State private var rendered = ""
    @State private var truncated = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if singleLine {
                ScrollView(.horizontal) {
                    Text(rendered)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
                Text(rendered)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if truncated {
                Text(L("仅预览前 32,000 字符；复制时保留完整内容。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: entryID) {
            let source = text
            if source.utf8.count <= Self.maximumPreviewCharacters {
                rendered = source; truncated = false
            } else {
                let result: (String, Bool) = await Task.detached(priority: .userInitiated) {
                    if let cutoff = source.index(source.startIndex, offsetBy: Self.maximumPreviewCharacters, limitedBy: source.endIndex),
                       cutoff < source.endIndex {
                        return (String(source[..<cutoff]), true)
                    }
                    return (source, false)
                }.value
                guard !Task.isCancelled else { return }
                rendered = result.0; truncated = result.1
            }
        }
    }
}

/// Leading mark of a history row: a small thumbnail for images, the kind symbol for everything else.
private struct ClipboardHistoryRow: View {
    let entry: ClipboardEntry
    let kind: ClipboardKind
    let line: String
    let onCopy: () -> Void
    let onToggleFavorite: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            ClipboardRowLeading(entry: entry, kind: kind)
            Text(line)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hovering {
                HStack(spacing: 2) {
                    WorkspaceIconButton(
                        symbol: entry.favorite ? "star.fill" : "star",
                        label: entry.favorite ? "取消收藏" : "收藏",
                        tint: entry.favorite ? .yellow : .secondary,
                        size: 22,
                        iconSize: 11,
                        action: onToggleFavorite
                    )
                    CopyIconButton(label: "复制", size: 22, iconSize: 11, action: onCopy)
                }
            } else if entry.favorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
                    .accessibilityLabel(L("已收藏"))
            } else {
                Text(Self.relativeTime(from: entry.capturedAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .frame(height: 34)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private static func relativeTime(from date: Date, now: Date = Date()) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(date)))
        if elapsed < 60 { return L("刚刚") }
        let minutes = elapsed / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
    }
}

/// Leading mark of a history row: a small thumbnail for images, the kind symbol for everything else.
private struct ClipboardRowLeading: View {
    let entry: ClipboardEntry
    let kind: ClipboardKind
    @State private var thumbnail: NSImage?
    var body: some View {
        let tint: Color = kind == .link ? .teal : .accentColor
        Group {
            if kind == .image {
                Group {
                    if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFill() }
                    else { Color.primary.opacity(0.08) }
                }
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
            } else {
                Image(systemName: kind.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .help(kind.title).accessibilityHidden(true)
        .task(id: entry.id) {
            guard thumbnail == nil, let data = entry.imageData else { return }
            thumbnail = await ClipboardThumbnails.image(data, key: entry.digest, maxPixels: 84, size: NSSize(width: 22, height: 22))
        }
    }
}

/// The preview decodes a screen-sized thumbnail off the main thread instead of the full image on every render.
private struct ClipboardPreviewImage: View {
    let entry: ClipboardEntry
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                // Shrink-only: keep the image at its natural point size when it fits the column,
                // and scale it down only when it is wider than the available space.
                ViewThatFits(in: .horizontal) {
                    Image(nsImage: image)
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                }
            } else {
                Color.primary.opacity(0.05).aspectRatio(4 / 3, contentMode: .fit).frame(maxWidth: 260)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5))
        .task(id: entry.id) {
            image = nil
            guard let data = entry.imageData else { return }
            image = await ClipboardThumbnails.image(data, key: entry.digest, maxPixels: 1200, size: nil)
        }
    }
}

enum ClipboardThumbnails {
    private final class Cache: @unchecked Sendable {
        let storage: NSCache<NSString, NSImage>
        init() {
            let cache = NSCache<NSString, NSImage>()
            cache.countLimit = 120
            cache.totalCostLimit = 32 * 1_024 * 1_024
            storage = cache
        }
    }
    private static let cache = Cache()
    nonisolated static func image(_ data: Data, key: String? = nil, maxPixels: Int, size: NSSize?) async -> NSImage? {
        let cacheKey = key.map { "\($0):\(maxPixels)" as NSString }
        if let cacheKey, let hit = cache.storage.object(forKey: cacheKey) { return hit }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let rendered = NSImage(cgImage: image, size: size ?? NSSize(width: image.width / 2, height: image.height / 2))
        if let cacheKey {
            let cost = image.bytesPerRow * image.height
            cache.storage.setObject(rendered, forKey: cacheKey, cost: cost)
        }
        return rendered
    }
}
