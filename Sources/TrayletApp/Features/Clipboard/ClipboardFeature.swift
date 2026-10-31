import AppKit
import SwiftUI
import Combine
import ImageIO

@MainActor final class ClipboardFeature: ObservableObject {
    static let collapsedWidth: CGFloat = 360
    static let expandedWidth: CGFloat = 700
    let controller: ClipboardController
    let imageEditing: ClipboardImageEditing
    var canEditImage: (() -> Bool)?
    var onEditImage: ((ClipboardPreparedImage) -> Bool)?
    var canRecognizeImage: (() -> Bool)?
    var onRecognizeImage: ((ClipboardPreparedImage) -> Bool)?
    private var imageObservations: Set<AnyCancellable> = []
    @Published private(set) var detailExpanded = false
    @Published private(set) var recordingConfirmationPresented = false
    @Published private(set) var recordingStarting = false
    private let presentWindow: (NSPanel) -> Void
    private let dismissWindow: (NSPanel) -> Void
    private weak var searchField: NSTextField?
    private var wantsSearchFocus = false
    private var panel: NSPanel?
    private var backing: V2GlassWindowBacking?
    private var dismissal: NSObjectProtocol?
    private var closeObservation: NSObjectProtocol?
    private var pendingRecordingConsent = false
    private var recordingTask: Task<Void, Never>?
    private var recordingRevision: UInt64 = 0
    private let preferences: Task<Void, Never>
    private var shuttingDown = false
    init(directory: URL, source: (any ClipboardSource)? = nil, writer: (any ClipboardWriting)? = nil, archive: (any V2ClipboardArchiving)? = nil, clock: @escaping () -> Date = Date.init,
         imageEditing: ClipboardImageEditing = ClipboardImageEditing(),
         presentWindow: @escaping (NSPanel) -> Void = { window in window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) },
         dismissWindow: @escaping (NSPanel) -> Void = { $0.orderOut(nil) }) {
        let controller = ClipboardController(source: source ?? V2ClipboardNativeSource(), writer: writer ?? V2ClipboardNativeWriter(), archive: archive ?? V2ClipboardArchive(directory: directory), clock: clock)
        self.controller = controller
        self.imageEditing = imageEditing
        self.presentWindow = presentWindow; self.dismissWindow = dismissWindow
        preferences = Task { await controller.loadPreferences() }
        controller.$query.removeDuplicates().dropFirst().sink { [weak imageEditing] _ in imageEditing?.cancel() }.store(in: &imageObservations)
        controller.$favoritesOnly.removeDuplicates().dropFirst().sink { [weak imageEditing] _ in imageEditing?.cancel() }.store(in: &imageObservations)
        controller.$selectedID.removeDuplicates().dropFirst().sink { [weak imageEditing] _ in imageEditing?.cancel() }.store(in: &imageObservations)
        controller.$entries.sink { [weak imageEditing] in imageEditing?.validate(entries: $0) }.store(in: &imageObservations)
    }
    /// Called after explicit user confirmation (or by a synthetic test); application launch never calls this.
    func start(poll: Bool = true) async {
        guard !shuttingDown else { return }
        await preferences.value
        guard !shuttingDown, !Task.isCancelled else { return }
        await controller.enable(poll: poll)
    }
    func requestRecording() {
        guard !shuttingDown, !controller.enabled, !recordingStarting else { return }
        pendingRecordingConsent = true
        recordingConfirmationPresented = true
    }
    /// SwiftUI hides an alert independently of its chosen button action, in either order.
    /// Hiding presentation alone must neither grant nor withdraw the pending choice.
    var recordingConfirmationBinding: Binding<Bool> {
        Binding(get: { self.recordingConfirmationPresented }, set: { visible in
            if !visible { self.recordingConfirmationPresented = false }
        })
    }
    func cancelRecording() {
        pendingRecordingConsent = false
        recordingConfirmationPresented = false
        // A confirmed start still waiting for preferences must not outlive a closed window.
        // Once enabled, ordinary navigation never changes the user's active recording choice.
        if !controller.enabled {
            recordingRevision &+= 1
            recordingTask?.cancel(); recordingTask = nil
            recordingStarting = false
        }
    }
    @discardableResult func confirmRecording(poll: Bool = true) -> Task<Void, Never>? {
        guard pendingRecordingConsent, !recordingStarting, !shuttingDown else { return nil }
        pendingRecordingConsent = false
        recordingConfirmationPresented = false
        recordingStarting = true
        recordingRevision &+= 1
        let revision = recordingRevision
        // Consume consent synchronously in the button action, before scheduling any work.
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if revision == self.recordingRevision {
                    self.recordingStarting = false
                    self.recordingTask = nil
                }
            }
            await self.start(poll: poll)
        }
        recordingTask = task
        return task
    }
    /// Double-click / Return on a row: copy it, and close the window only when the copy really succeeded.
    func copyAndClose(_ id: UUID) {
        if controller.copy(id) { imageEditing.cancel(); if let panel { dismissWindow(panel) } }
    }
    func copySelectedAndClose() {
        guard let entry = controller.selectedEntry else { return }
        copyAndClose(entry.id)
    }
    func dismiss() { cancelRecording(); imageEditing.cancel(); if let panel { dismissWindow(panel) } }
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
    @discardableResult func queueFavoriteMove(from offsets: IndexSet, to destination: Int) -> Task<Bool, Never> {
        // AppKit supplies offsets for this exact visible prefix, before the async action is queued.
        let expectedOrder = controller.orderedFavoriteIDs
        return Task { [weak self] in
            guard let self, self.controller.orderedFavoriteIDs == expectedOrder else { return false }
            return await self.moveFavorites(from: offsets, to: destination)
        }
    }
    func present() {
        wantsSearchFocus = true
        if panel == nil {
            let width = detailExpanded ? Self.expandedWidth : Self.collapsedWidth
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = V2L("剪贴板"); window.minSize = Self.minimumSize(expanded: detailExpanded)
            window.isReleasedWhenClosed = false
            backing = V2GlassWindowBacking(window: window, content: NSHostingView(rootView: ClipboardFeatureView(feature: self)))
            window.center(); panel = window
            dismissal = V2FloatingWindow.hideOnResignKey(window) { [weak self] in self?.dismiss() }
            closeObservation = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelRecording(); self?.imageEditing.cancel() }
            }
        }
        refreshTitle()
        controller.reconcileVisibleSelection()
        if let panel {
            panel.contentView?.layoutSubtreeIfNeeded()
            presentWindow(panel)
            focusSearchIfNeeded()
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
    /// The detail column opens to the right of the list; the window widens instead of squeezing the list.
    func setDetailExpanded(_ value: Bool) {
        guard value != detailExpanded else { return }
        detailExpanded = value
        guard let panel else { return }
        panel.minSize = Self.minimumSize(expanded: value)
        var frame = panel.frame
        frame.size.width = max(panel.minSize.width, value ? max(frame.width, Self.expandedWidth) : Self.collapsedWidth)
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame, frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
        panel.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    private static func minimumSize(expanded: Bool) -> NSSize { NSSize(width: expanded ? 580 : 300, height: 320) }
    func refreshTitle() { panel?.title = V2L("剪贴板") }
    func shutdown() { shuttingDown = true; cancelRecording(); imageEditing.cancel(); controller.stop(); panel?.close(); Task { await controller.shutdown() } }
    func shutdownAndWait() async { shuttingDown = true; cancelRecording(); imageEditing.cancel(); panel?.close(); await controller.shutdown() }
}

extension ClipboardKind {
    @MainActor var title: String { switch self { case .text: V2L("文本"); case .link: V2L("链接"); case .image: V2L("图片") } }
}

@MainActor struct ClipboardFeatureView: View {
    @ObservedObject private var feature: ClipboardFeature
    @ObservedObject private var localization = V2Localization.shared
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
                    ProgressView().controlSize(.small).accessibilityLabel(V2L("正在准备图片…"))
                    Button(V2L("取消")) { imageEditing.cancel() }
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    ClipboardSearchField(feature: feature)
                }
                .padding(.horizontal, 12).frame(height: 30)
                .v2GlassBackground(in: Capsule())
                Button { feature.setDetailExpanded(!feature.detailExpanded) } label: {
                    Image(systemName: "sidebar.right").frame(width: 28, height: 28)
                }.buttonStyle(.borderless)
                    .help(V2L(feature.detailExpanded ? "折叠详情" : "展开详情"))
                    .accessibilityLabel(V2L(feature.detailExpanded ? "折叠详情" : "展开详情"))
                    .accessibilityAddTraits(feature.detailExpanded ? .isSelected : [])
            }.padding(12)
            Divider()
            HStack(spacing: 0) {
                historyList.frame(minWidth: 260, idealWidth: 340, maxWidth: feature.detailExpanded ? 340 : .infinity)
                if feature.detailExpanded {
                    Divider()
                    preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    // The storage state is a standing privacy notice, so it keeps its own line and icon.
                    Label(V2L(controller.settings.saveLocally ? "本机未加密保存" : (controller.hasFavorites ? "收藏已未加密保存在本机" : "仅内存")),
                          systemImage: controller.settings.saveLocally || controller.hasFavorites ? "lock.open" : "memorychip")
                        .font(.caption).foregroundStyle(controller.settings.saveLocally || controller.hasFavorites ? Color.orange : Color.secondary)
                }
                Spacer(minLength: 0)
                if !controller.enabled { ClipboardRecordingControl(feature: feature) }
                if controller.ignoringNextCopy {
                    Button { controller.setIgnoringNextCopy(false) } label: { Image(systemName: "eye.slash.fill").frame(width: 28, height: 28) }
                        .buttonStyle(.plain).accessibilityLabel(V2L("取消忽略下一次复制"))
                        .help(V2L("将跳过下一次检测到的外部变化；不读取正文。自复制不计入，暂停时保留。"))
                }
                Menu {
                    Toggle(V2L("仅收藏"), isOn: $controller.favoritesOnly)
                    if controller.enabled { Button(V2L(controller.paused ? "恢复" : "暂停")) { controller.paused ? controller.resume() : controller.pause() } }
                    Toggle(V2L("忽略下一次复制"), isOn: Binding(get: { controller.ignoringNextCopy }, set: controller.setIgnoringNextCopy))
                        .disabled(!controller.enabled)
                    if controller.canRetryFavoritesLoading {
                        Button(V2L("重试加载收藏")) { Task { await controller.retryFavoritesLoading() } }
                    }
                    if let entry = controller.selectedEntry, !controller.display(entry).text.isEmpty {
                        Button(V2L("复制纯文本")) { controller.copy(entry.id, format: .plainText) }
                    }
                    if let entry = controller.selectedEntry {
                        imageEditActions(entry)
                        imageRecognitionActions(entry)
                        if entry.favorite { favoriteMoveActions(entry) }
                    }
                    Divider()
                    Button(V2L("清空"), role: .destructive) { confirmClear = true }
                    Button(V2L("删除所有收藏…"), role: .destructive) { confirmDeleteFavorites = true }.disabled(!controller.hasFavorites)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help(V2L("更多")).accessibilityLabel(V2L("更多"))
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .onExitCommand { feature.dismiss() }
        .onChange(of: localization.languageCode) { _, _ in feature.refreshTitle() }
        .alert(V2L("删除所有收藏？"), isPresented: $confirmDeleteFavorites) {
            Button(V2L("取消"), role: .cancel) {}
            Button(V2L("删除所有收藏"), role: .destructive) { Task { await controller.deleteAllFavorites() } }
        } message: { Text(V2L("将删除内存和本机保存的全部收藏内容，不修改当前系统剪贴板。")) }
        .alert(V2L("清空剪贴板历史？"), isPresented: $confirmClear) {
            Button(V2L("取消"), role: .cancel) {}
            Button(V2L("清空"), role: .destructive) { Task { await controller.clear() } }
        } message: { Text(V2L("将清空非收藏的历史；收藏保留在本机。不修改当前系统剪贴板。")) }
        .alert(V2L("删除这条剪贴板历史？"), isPresented: $confirmDelete) {
            Button(V2L("取消"), role: .cancel) { controller.cancelDeletion() }
            Button(V2L("删除"), role: .destructive) { Task { await controller.confirmDeletion() } }
        } message: { Text(V2L("同时删除本机保存的这一项（含收藏），不修改当前系统剪贴板。")) }
    }
    /// Every row has the same height; long text is truncated to one line with an ellipsis.
    private var historyList: some View {
        List(selection: $controller.selectedID) {
            ForEach(controller.filteredEntries) { entry in
                let display = controller.display(entry)
                let line = display.line ?? V2L("图片")
                HStack(spacing: 10) {
                    ClipboardRowLeading(entry: entry, kind: display.kind)
                    Text(line).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    if entry.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel(V2L("已收藏")) }
                }
                .frame(height: 40).tag(entry.id).listRowSeparator(.visible)
                .moveDisabled(!entry.favorite || !controller.query.isEmpty)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(display.kind.title + ", " + line)
            }
            .onMove { offsets, destination in feature.queueFavoriteMove(from: offsets, to: destination) }
        }
        .listStyle(.plain).environment(\.defaultMinListRowHeight, 40)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let entry = controller.entries.first(where: { $0.id == id }) {
                Button(V2L("复制")) { controller.copy(id) }
                Button(V2L("复制纯文本")) { controller.copy(id, format: .plainText) }.disabled(controller.display(entry).text.isEmpty)
                Button(V2L(entry.favorite ? "取消收藏" : "收藏")) { Task { await controller.toggleFavorite(id) } }
                imageEditActions(entry)
                imageRecognitionActions(entry)
                if entry.favorite { favoriteMoveActions(entry) }
                Button(V2L("删除"), role: .destructive) { requestDeletion(id) }
            }
        } primaryAction: { ids in if let id = ids.first { feature.copyAndClose(id) } }
        .overlay { if controller.filteredEntries.isEmpty { Text(V2L("暂无匹配历史")).foregroundStyle(.secondary) } }
    }
    private var statusMessage: String {
        if let message = imageEditing.message { return V2L(message) }
        if let message = controller.message { return V2L(message) }
        if !controller.enabled { return V2L("记录已关闭") }
        if controller.paused { return V2L("已暂停；恢复时不会补录暂停期间内容。") }
        return String(format: V2L("%d / %d 条 · 保留 %d 天"), controller.entries.count, controller.settings.maximumCount, controller.settings.retentionDays)
    }
    @ViewBuilder private var preview: some View {
        if let entry = controller.selectedEntry {
            let display = controller.display(entry)
            let kind = display.kind
            VStack(alignment: .leading, spacing: 12) {
                Label(kind.title, systemImage: kind.symbol).font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text(V2L("时间")).foregroundStyle(.secondary); Text(entry.capturedAt.formatted(date: .abbreviated, time: .shortened)) }
                    GridRow { Text(V2L("来源")).foregroundStyle(.secondary); Text(entry.application).lineLimit(1).truncationMode(.middle) }
                    GridRow {
                        Text(V2L("大小")).foregroundStyle(.secondary)
                        if kind != .image { Text(String(format: V2L("%d 字符"), display.text.count)) }
                        else { Text(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file)) }
                    }
                }.font(.caption)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if entry.imageData != nil { ClipboardPreviewImage(entry: entry) }
                        if !display.text.isEmpty { Text(display.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }.padding(12)
                }.v2GlassBackground(in: RoundedRectangle(cornerRadius: V2Design.Radius.card))
                HStack {
                    Button(V2L("复制")) { controller.copy(entry.id) }.buttonStyle(.borderedProminent).keyboardShortcut("c", modifiers: [.command, .shift])
                    Button { Task { await controller.toggleFavorite(entry.id) } } label: {
                        Image(systemName: entry.favorite ? "star.fill" : "star")
                    }.accessibilityLabel(V2L(entry.favorite ? "取消收藏" : "收藏"))
                        .help(V2L("收藏会把内容未加密保存在本机，不会被自动清理"))
                    if entry.imageData != nil {
                        Menu { imageEditActions(entry); imageRecognitionActions(entry) } label: { Image(systemName: "photo") }
                            .menuStyle(.borderedButton).fixedSize().disabled(imageEditing.isPreparing)
                            .help(V2L("图片操作")).accessibilityLabel(V2L("图片操作"))
                    }
                    Spacer()
                    Button(V2L("删除"), role: .destructive) { requestDeletion(entry.id) }
                }
            }.padding(16)
        } else {
            Text(V2L(controller.filteredEntries.isEmpty ? "暂无匹配历史" : "选择一项预览")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func requestDeletion(_ id: UUID) {
        controller.requestDeletion(id)
        confirmDelete = controller.pendingDeletionID != nil
    }
    @ViewBuilder private func imageEditActions(_ entry: ClipboardEntry, compact: Bool = false) -> some View {
        let indices = ClipboardImageEditing.imageIndices(in: entry)
        if indices.count == 1, let index = indices.first {
            Button { feature.editImage(entry.id, itemIndex: index) } label: {
                if compact { Image(systemName: "pencil") } else { Text(V2L("编辑图片")) }
            }.disabled(imageEditing.isPreparing).help(V2L("编辑副本，保留历史原件")).accessibilityLabel(V2L("编辑图片"))
        } else if !indices.isEmpty {
            Menu(V2L("编辑图片")) {
                ForEach(Array(indices.enumerated()), id: \.element) { offset, index in
                    Button(String(format: V2L("图片 %d"), offset + 1)) { feature.editImage(entry.id, itemIndex: index) }
                }
            }.disabled(imageEditing.isPreparing)
        }
    }
    @ViewBuilder private func imageRecognitionActions(_ entry: ClipboardEntry) -> some View {
        let indices = ClipboardImageEditing.imageIndices(in: entry)
        if indices.count == 1, let index = indices.first {
            Button(V2L("识别文字")) { feature.recognizeImage(entry.id, itemIndex: index) }
                .disabled(imageEditing.isPreparing).help(V2L("本机识别，校正后再翻译"))
        } else if !indices.isEmpty {
            Menu(V2L("识别文字")) {
                ForEach(Array(indices.enumerated()), id: \.element) { offset, index in
                    Button(String(format: V2L("图片 %d"), offset + 1)) { feature.recognizeImage(entry.id, itemIndex: index) }
                }
            }.disabled(imageEditing.isPreparing)
        }
    }
    @ViewBuilder private func favoriteMoveActions(_ entry: ClipboardEntry) -> some View {
        let ids = controller.orderedFavoriteIDs
        let index = ids.firstIndex(of: entry.id)
        Button(V2L("收藏上移")) { moveFavorite(entry.id, offset: -1) }
            .disabled(!controller.query.isEmpty || index == nil || index == 0)
        Button(V2L("收藏下移")) { moveFavorite(entry.id, offset: 1) }
            .disabled(!controller.query.isEmpty || index == nil || index == ids.count - 1)
    }
    private func moveFavorite(_ id: UUID, offset: Int) {
        var ids = controller.orderedFavoriteIDs
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        Task { await controller.reorderFavorites(ids) }
    }
}

@MainActor struct ClipboardFeatureSettingsView: View {
    let feature: ClipboardFeature
    @ObservedObject private var localization = V2Localization.shared
    @ObservedObject private var controller: ClipboardController
    @State private var confirmPersistence = false
    @State private var exclusions = ""
    init(feature: ClipboardFeature) { self.feature = feature; controller = feature.controller }
    var body: some View {
        Form {
            Section {
                LabeledContent(V2L("剪贴板记录")) { ClipboardRecordingControl(feature: feature) }
            }
            Section {
                LabeledContent(V2L("最大数量")) {
                    ClipboardLimitField("最大数量", unit: "条", value: setting(\.maximumCount), range: 1...1000)
                }
                LabeledContent(V2L("保留期限")) {
                    ClipboardLimitField("保留期限", unit: "天", value: setting(\.retentionDays), range: 1...30)
                }
            }
            Section {
                Toggle(V2L("文字与富文本"), isOn: captureSetting(\.captureText))
                Toggle(V2L("图片"), isOn: captureSetting(\.captureImages))
            } header: {
                Text(V2L("记录类型"))
            } footer: {
                if !controller.settings.capturePolicy.hasEnabledType {
                    Text(V2L("未选择类型，不记录新内容。"))
                }
            }
            .help(V2L("混合复制须全部允许，保留原格式。富文本可含内嵌内容，图片可附带文字。"))
            Section {
                Toggle(V2L("在本机未加密保存历史"), isOn: Binding(get: { controller.settings.saveLocally }, set: { value in
                    if value { confirmPersistence = true } else { update { $0.saveLocally = false } }
                }))
            } footer: {
                Text(V2L("收藏始终保存在本机（未加密）。")).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section(V2L("排除应用")) {
                HStack {
                    TextField(V2L("排除应用"), text: $exclusions, prompt: Text(V2L("Bundle ID，以逗号分隔"))).labelsHidden()
                        .onSubmit { applyExclusions() }
                    Button(V2L("应用")) { applyExclusions() }
                }
            }
            Section {
                HStack {
                    if let message = controller.message { Text(V2L(message)).foregroundStyle(.secondary) }
                    Spacer()
                    Button(V2L("打开剪贴板")) { feature.present() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { exclusions = controller.settings.excludedApplications.sorted().joined(separator: ", ") }
        .alert(V2L("允许在本机未加密保存？"), isPresented: $confirmPersistence) {
            Button(V2L("取消"), role: .cancel) {}
            Button(V2L("允许未加密保存")) { update { $0.saveLocally = true } }
        } message: { Text(V2L("正文保存在本用户的 Application Support/Traylet/v2/clipboard，运行时按所选期限清理；退出期间不运行，下次启动时清理过期内容。同用户权限的程序、系统备份可能读取；不提供加密或安全擦除保证。")) }
    }
    private func setting(_ key: WritableKeyPath<ClipboardSettings, Int>) -> Binding<Int> {
        Binding(get: { controller.settings[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } })
    }
    private func captureSetting(_ key: WritableKeyPath<ClipboardSettings, Bool>) -> Binding<Bool> {
        Binding(get: { controller.settings[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } })
    }
    private func applyExclusions() {
        update { $0.excludedApplications = Set(exclusions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }) }
    }
    private func update(_ change: @escaping (inout ClipboardSettings) -> Void) {
        Task { var value = controller.settings; change(&value); await controller.updateSettings(value) }
    }
}

/// A per-run consent action shared by history and Settings; never inferred from storage preferences.
@MainActor private struct ClipboardRecordingControl: View {
    @ObservedObject private var feature: ClipboardFeature
    @ObservedObject private var controller: ClipboardController
    init(feature: ClipboardFeature) { self.feature = feature; controller = feature.controller }
    var body: some View {
        Group {
            if controller.enabled {
                Button(V2L(controller.paused ? "恢复记录" : "暂停记录")) {
                    controller.paused ? controller.resume() : controller.pause()
                }
            } else {
                Button(V2L("开启记录…")) { feature.requestRecording() }.disabled(feature.recordingStarting)
            }
        }
        .alert(V2L("开启剪贴板记录？"), isPresented: feature.recordingConfirmationBinding) {
            Button(V2L("取消"), role: .cancel) { feature.cancelRecording() }
            Button(V2L("开启记录")) {
                feature.confirmRecording()
            }
        } message: {
            Text(V2L("仅本次运行记录之后复制的文本、链接和图片，不补录当前内容，退出后默认关闭。普通历史默认仅内存；如已选择本机保存，将未加密写入 Application Support/Traylet/v2/clipboard，按设置的数量与期限清理。敏感标记和排除应用会跳过，但无法识别所有密码。"))
        }
        .onDisappear { feature.cancelRecording() }
    }
}

/// Leading mark of a history row: a small thumbnail for images, the kind symbol for everything else.
private struct ClipboardRowLeading: View {
    let entry: ClipboardEntry
    let kind: ClipboardKind
    @State private var thumbnail: NSImage?
    var body: some View {
        Group {
            if kind == .image {
                Group {
                    if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFill() }
                    else { Color.primary.opacity(0.08) }
                }.frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: kind.symbol).foregroundStyle(.secondary).frame(width: 28, height: 28)
            }
        }
        .help(kind.title).accessibilityHidden(true)
        .task(id: entry.id) {
            guard thumbnail == nil, let data = entry.imageData else { return }
            thumbnail = await ClipboardThumbnails.image(data, maxPixels: 84, size: NSSize(width: 28, height: 28))
        }
    }
}

/// The preview decodes a screen-sized thumbnail off the main thread instead of the full image on every render.
private struct ClipboardPreviewImage: View {
    let entry: ClipboardEntry
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Color.primary.opacity(0.05).aspectRatio(4 / 3, contentMode: .fit) }
        }
        .frame(maxHeight: 260)
        .task(id: entry.id) {
            image = nil
            guard let data = entry.imageData else { return }
            image = await ClipboardThumbnails.image(data, maxPixels: 1200, size: nil)
        }
    }
}

enum ClipboardThumbnails {
    nonisolated static func image(_ data: Data, maxPixels: Int, size: NSSize?) async -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: size ?? NSSize(width: image.width / 2, height: image.height / 2))
    }
}
