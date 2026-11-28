import AppKit
import SwiftUI
import TrayletCore

struct TranslationConfigurationView: View {
    @ObservedObject var configuration: TranslationConfiguration
    @ObservedObject private var localization = Localization.shared
    @StateObject private var languagePacks: TranslationLanguagePackController
    @State private var showsStorageRecovery = false
    @State private var showsModelPicker = false
    @State private var promptExpanded: Bool
    @State private var expanded: Set<TranslationEngineChoice>
    @State private var dragging: TranslationEngineChoice?
    @State private var endpointDraft: String
    @State private var modelDraft: String
    @State private var credentialDraft: String
    @State private var deeplKeyDraft: String
    @State private var customPromptDraft: String
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var modelFieldFocused: Bool
    init(configuration: TranslationConfiguration, expanded: Set<TranslationEngineChoice> = [],
         languagePacks: TranslationLanguagePackController = TranslationLanguagePackController()) {
        self.configuration = configuration
        _promptExpanded = State(initialValue: !configuration.customPrompt.isEmpty)
        _expanded = State(initialValue: expanded)
        _languagePacks = StateObject(wrappedValue: languagePacks)
        _endpointDraft = State(initialValue: configuration.endpoint)
        _modelDraft = State(initialValue: configuration.model)
        _credentialDraft = State(initialValue: configuration.credential)
        _deeplKeyDraft = State(initialValue: configuration.deeplKey)
        _customPromptDraft = State(initialValue: configuration.customPrompt)
    }
    var body: some View {
        Form {
            TranslationLanguagePackSettings(controller: languagePacks)
            Section(L("翻译窗口")) {
                LabeledContent(L("显示引擎图标")) {
                    HStack(spacing: 6) {
                        Text("\(configuration.maxVisible)").monospacedDigit()
                        Stepper(L("显示引擎图标"), value: $configuration.maxVisible, in: TranslationConfiguration.visibleRange).labelsHidden()
                    }
                    .help(L("翻译窗口会按此数量加宽最小宽度，保证最小窗口下图标全部可见；超出个数的引擎不显示。"))
                }
            }
            Section(L("翻译引擎")) {
                engineRow(configuration.engine)
                configurationRows(configuration.engine)
                ForEach(configuration.sortableEngines) { engine in
                    engineRow(engine)
                        .onDrop(of: [.text], delegate: EngineDropDelegate(target: engine, configuration: configuration, dragging: $dragging))
                    configurationRows(engine)
                }
            }
            if configuration.storageIssue != nil || configuration.storageRecoveryNotice != nil {
                Section {
                    if let issue = configuration.storageIssue {
                        Label(L(issue), systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        Button(L("备份并恢复默认配置")) { configuration.requestStorageRecovery(); showsStorageRecovery = configuration.storageRecoveryRequested }
                    }
                    if let notice = configuration.storageRecoveryNotice { Text(configuration.localizedStorageRecoveryNotice ?? notice).textSelection(.enabled) }
                }
            }
        }
        .formStyle(.grouped)
        .background {
            if let request = languagePacks.request {
                TranslationLanguagePackHost(request: request) { outcome in
                    _ = languagePacks.completeDownload(request.id, outcome: outcome)
                }
                .id(request.id)
            }
        }
        .onDisappear { flushDrafts(); configuration.cancel(); languagePacks.cancel() }
        .onChange(of: configuration.endpoint) { _, value in if endpointDraft != value { endpointDraft = value } }
        .onChange(of: configuration.model) { _, value in if modelDraft != value { modelDraft = value } }
        .onChange(of: configuration.credential) { _, value in if credentialDraft != value { credentialDraft = value } }
        .onChange(of: configuration.deeplKey) { _, value in if deeplKeyDraft != value { deeplKeyDraft = value } }
        .onChange(of: configuration.customPrompt) { _, value in if customPromptDraft != value { customPromptDraft = value } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            flushDrafts()
        }
        .alert(L("备份并恢复默认配置？"), isPresented: $showsStorageRecovery) {
            Button(L("取消"), role: .cancel) { configuration.cancelStorageRecovery() }
            Button(L("备份并恢复")) { configuration.confirmStorageRecovery() }
        } message: {
            Text(L("将保留当前 v2 配置文件的独立备份，恢复系统翻译默认值，并清除本机加密保存的 API Key。不会读取或修改旧版本配置或其他数据。"))
        }
    }
    /// Checkbox, icon and name, then the configure pill and a drag handle; the pinned default shows a badge instead of the handle.
    private func engineRow(_ engine: TranslationEngineChoice) -> some View {
        let isDefault = configuration.engine == engine
        let enabled = configuration.isEnabled(engine)
        let configurable = engine == .ai || engine == .deepl
        let open = configurable && expanded.contains(engine)
        let title = L(TranslationWorkspaceView.engineTitle(engine))
        let list = configuration.sortableEngines
        return HStack(spacing: 10) {
            Toggle(title, isOn: Binding(get: { enabled }, set: { configuration.setEnabled(engine, $0) }))
                .labelsHidden().toggleStyle(.checkbox).disabled(engine == .system || isDefault)
            TranslationEngineIcon(engine: engine, size: 18).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                engineBadge(engine)
            }
            Spacer(minLength: 8)
            if configurable {
                EngineConfigureButton(open: open, title: title) {
                    withAnimation(Design.Animation.snappy) { if open { expanded.remove(engine) } else { expanded.insert(engine) } }
                }
            }
            EngineDefaultControl(isDefault: isDefault, title: title) {
                configuration.engine = engine
            }
            if !isDefault {
                Image(systemName: "line.3.horizontal").font(.system(size: 13, weight: .medium)).foregroundStyle(.tertiary)
                    .frame(width: 24, height: 28).contentShape(Rectangle())
                    .help(L("拖动调整顺序")).accessibilityHidden(true)
            }
        }
        .frame(minHeight: 36).contentShape(Rectangle())
        .onDrag {
            guard !isDefault else { return NSItemProvider() }
            dragging = engine
            return NSItemProvider(object: engine.rawValue as NSString)
        }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            if !isDefault { Button(L("设为默认") + " " + title) { configuration.engine = engine } }
            if !isDefault, list.first != engine { Button(L("上移") + " " + title) { configuration.move(engine, by: -1) } }
            if !isDefault, list.last != engine { Button(L("下移") + " " + title) { configuration.move(engine, by: 1) } }
        }
    }
    /// A short capsule badge under an engine title, replacing the previous verbose subtitle.
    private func engineBadge(_ engine: TranslationEngineChoice) -> some View {
        let tint: Color = switch engine {
        case .system: .green
        case .ai, .deepl: .accentColor
        case .google, .myMemory: .secondary
        }
        return StatusPill(text: L(Self.note(engine)), tint: tint)
    }
    /// An open engine's settings are ordinary form rows right under it, indented past the checkbox.
    @ViewBuilder private func configurationRows(_ engine: TranslationEngineChoice) -> some View {
        if (engine == .ai || engine == .deepl) && expanded.contains(engine) {
            Group { if engine == .ai { aiConfiguration } else { deeplConfiguration } }
                .padding(.leading, 32)
        }
    }
    @ViewBuilder private var aiConfiguration: some View {
        Picker(L("提供商"), selection: $configuration.provider) { ForEach(TranslationAIProvider.allCases) { Text(L($0.title)).tag($0) } }
        TextField(L("服务地址"), text: debouncedBinding($endpointDraft), prompt: Text(verbatim: "https://example.com/v1"))
            .disabled(configuration.provider == .openAI)
            .onSubmit { flushDrafts() }
            .help(L("本机 HTTP 仅支持 localhost、127.0.0.1 或 ::1"))
        AIModelComboField(
            model: debouncedBinding($modelDraft),
            models: configuration.models,
            showsPicker: $showsModelPicker,
            focused: $modelFieldFocused,
            identifier: "translation.model-list",
            onCommit: flushDrafts
        )
        .onChange(of: configuration.models) { _, models in
            showsModelPicker = !models.isEmpty
        }
        .onChange(of: configuration.feedback(for: .models)) { _, feedback in
            if case .success? = feedback, !configuration.models.isEmpty { showsModelPicker = true }
        }
        SecureField(L("API Key"), text: debouncedBinding($credentialDraft), prompt: Text(L("本机加密保存")))
            .onSubmit { flushDrafts() }
        DisclosureGroup(L("自定义提示词"), isExpanded: $promptExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                PromptTextEditor(text: debouncedBinding($customPromptDraft), placeholder: L("留空使用默认提示词，支持 {source} 与 {target}"))
                if !customPromptDraft.isEmpty {
                    HStack {
                        Spacer()
                        Button(L("恢复默认提示词")) {
                            customPromptDraft = ""
                            configuration.customPrompt = ""
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(.top, 4)
        }
        HStack(spacing: 8) {
            Spacer()
            AISettingsActionButton(
                isRunning: configuration.isRunning(.models),
                feedback: configuration.feedback(for: .models),
                isBusy: configuration.isBusy,
                idle: "获取模型",
                running: "获取中…",
                success: "获取成功",
                failure: "获取失败",
                help: "向当前服务地址请求模型列表，不发送原文、截图或剪贴板。",
                identifier: "translation.fetch-models"
            ) {
                flushDrafts()
                modelFieldFocused = true
                configuration.runSettingsAction(.models)
            }
            AISettingsActionButton(
                isRunning: configuration.isRunning(.connection),
                feedback: configuration.feedback(for: .connection),
                isBusy: configuration.isBusy,
                idle: "测试连接",
                running: "测试中…",
                success: "连接成功",
                failure: "连接失败",
                help: "请求当前服务的模型列表，不发送原文、截图或剪贴板。",
                identifier: "translation.test-connection"
            ) {
                flushDrafts()
                configuration.runSettingsAction(.connection)
            }
        }
    }
    @ViewBuilder private var deeplConfiguration: some View {
        SecureField(L("API Key"), text: debouncedBinding($deeplKeyDraft), prompt: Text(L("本机加密保存")))
            .onSubmit { flushDrafts() }
        HStack {
            Spacer()
            AISettingsActionButton(
                isRunning: configuration.isRunning(.deeplTranslate),
                feedback: configuration.feedback(for: .deeplTranslate),
                isBusy: configuration.isBusy || deeplKeyDraft.isEmpty,
                idle: "测试连接",
                running: "测试中…",
                success: "连接成功",
                failure: "连接失败",
                help: "发送固定短句 Hello. 测试连接，不发送原文、截图或剪贴板。",
                identifier: "translation.test-deepl"
            ) {
                flushDrafts()
                configuration.runSettingsAction(.deeplTranslate)
            }
        }
    }
    private func debouncedBinding(_ draft: Binding<String>) -> Binding<String> {
        Binding(get: { draft.wrappedValue }, set: { next in
            guard draft.wrappedValue != next else { return }
            draft.wrappedValue = next
            debounceTask?.cancel()
            debounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                flushDrafts()
            }
        })
    }
    private func flushDrafts() {
        debounceTask?.cancel(); debounceTask = nil
        if configuration.endpoint != endpointDraft { configuration.endpoint = endpointDraft }
        if configuration.model != modelDraft { configuration.model = modelDraft }
        if configuration.credential != credentialDraft { configuration.credential = credentialDraft }
        if configuration.deeplKey != deeplKeyDraft { configuration.deeplKey = deeplKeyDraft }
        if configuration.customPrompt != customPromptDraft { configuration.customPrompt = customPromptDraft }
    }
    private static func note(_ engine: TranslationEngineChoice) -> String {
        switch engine {
        case .system: "本机 · 离线"
        case .ai, .deepl: "需密钥"
        case .google, .myMemory: "免费"
        }
    }
}

enum TranslationModelFilter {
    static func matching(_ models: [String], query: String) -> [String] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return models }
        return models.filter { $0.localizedCaseInsensitiveContains(term) }
    }
}

struct TranslationModelPicker: View {
    let models: [String]
    @Binding var selection: String
    @Binding var isPresented: Bool
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private var matches: [String] { TranslationModelFilter.matching(models, query: query) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("选择模型")).font(.headline)
                Spacer()
                if !models.isEmpty {
                    Text("\(matches.count)/\(models.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            if models.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 18)).foregroundStyle(.tertiary)
                    Text(L("尚未获取模型")).font(.callout).foregroundStyle(.secondary)
                    Text(L("先点击“获取模型”获取可用模型列表。")).font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 88)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("搜索模型"), text: $query, prompt: Text(L("输入模型名称筛选")))
                        .labelsHidden().textFieldStyle(.plain).focused($searchFocused)
                    if !query.isEmpty {
                        Button { query = ""; searchFocused = true } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).help(L("清除搜索")).accessibilityLabel(L("清除搜索"))
                    }
                }
                .padding(.horizontal, 8).frame(height: 28)
                .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 10).padding(.bottom, 8)
                Divider()
                if matches.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(.tertiary)
                        Text(L("没有匹配的模型")).font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 88)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(matches, id: \.self) { model in
                                TranslationModelRow(model: model, selected: selection == model) {
                                    selection = model
                                    isPresented = false
                                }
                            }
                        }.padding(.vertical, 4)
                    }
                    .frame(height: min(CGFloat(matches.count) * 32 + 8, 240))
                }
            }
        }
        .frame(width: 360)
        .task {
            await Task.yield()
            if !models.isEmpty { searchFocused = true }
        }
        .onExitCommand { isPresented = false }
    }
}

private struct TranslationModelRow: View {
    let model: String
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 14)
                Text(model).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(selected ? Color.accentColor.opacity(0.12) : hovering ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(model)
        .accessibilityValue(L(selected ? "已选择" : "未选择"))
    }
}

/// Reorders live as the dragged row passes over another, so the list shows the drop position before release.
private struct EngineDropDelegate: DropDelegate {
    let target: TranslationEngineChoice
    let configuration: TranslationConfiguration
    @Binding var dragging: TranslationEngineChoice?
    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        MainActor.assumeIsolated { withAnimation(.snappy(duration: 0.2)) { configuration.move(dragging, to: target) } }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}
