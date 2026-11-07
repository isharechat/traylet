import AppKit
import SwiftUI
import TrayletCore

struct TranslationConfigurationView: View {
    @ObservedObject var configuration: TranslationConfiguration
    @ObservedObject private var localization = V2Localization.shared
    @StateObject private var languagePacks: TranslationLanguagePackController
    @State private var showsStorageRecovery = false
    @State private var showsModelPicker = false
    @State private var expanded: Set<TranslationEngineChoice>
    @State private var dragging: TranslationEngineChoice?
    @State private var accessibilityGranted = V2AccessibilitySelectedText.isTrusted
    @FocusState private var modelFieldFocused: Bool
    init(configuration: TranslationConfiguration, expanded: Set<TranslationEngineChoice> = [],
         languagePacks: TranslationLanguagePackController = TranslationLanguagePackController()) {
        self.configuration = configuration
        _expanded = State(initialValue: expanded)
        _languagePacks = StateObject(wrappedValue: languagePacks)
    }
    var body: some View {
        Form {
            TranslationLanguagePackSettings(controller: languagePacks)
            Section {
                Picker(V2L("默认翻译引擎"), selection: $configuration.engine) {
                    ForEach(TranslationEngineChoice.allCases) { Text(V2L(TranslationWorkspaceView.engineTitle($0))).tag($0) }
                }
                LabeledContent(V2L("最多显示引擎图标")) {
                    HStack(spacing: 6) {
                        Text("\(configuration.maxVisible)").monospacedDigit()
                        Stepper(V2L("最多显示引擎图标"), value: $configuration.maxVisible, in: TranslationConfiguration.visibleRange).labelsHidden()
                    }
                }
            }
            Section {
                LabeledContent(V2L("读取选中文本")) {
                    HStack(spacing: 8) {
                        Text(V2L(accessibilityGranted ? "已授权" : "未授权"))
                            .foregroundStyle(accessibilityGranted ? Color.secondary : Color.orange)
                        Button(V2L(accessibilityGranted ? "系统设置" : "请求权限")) {
                            if accessibilityGranted { V2AccessibilitySelectedText.openSettings() }
                            else { V2AccessibilitySelectedText.requestTrust() }
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text(V2L("辅助功能"))
            } footer: {
                Text(V2L("允许 Traylet 在按下输入翻译快捷键时读取其他应用的选中文本；修改授权后回到本页会自动刷新状态，如仍无法读取请重新打开 Traylet。"))
            }
            Section(V2L("翻译引擎")) {
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
                        Label(V2L(issue), systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        Button(V2L("备份并恢复默认配置")) { configuration.requestStorageRecovery(); showsStorageRecovery = configuration.storageRecoveryRequested }
                    }
                    if let notice = configuration.storageRecoveryNotice { Text(configuration.localizedStorageRecoveryNotice ?? notice).textSelection(.enabled) }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { configuration.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = V2AccessibilitySelectedText.isTrusted
        }
        .alert(V2L("备份并恢复默认配置？"), isPresented: $showsStorageRecovery) {
            Button(V2L("取消"), role: .cancel) { configuration.cancelStorageRecovery() }
            Button(V2L("备份并恢复")) { configuration.confirmStorageRecovery() }
        } message: {
            Text(V2L("将保留当前 v2 配置文件的独立备份，恢复系统翻译默认值，并清除钥匙串中的 API Key。不会读取或修改旧版本配置或其他数据。"))
        }
    }
    /// Checkbox, icon and name, then the configure pill and a drag handle; the pinned default shows a badge instead of the handle.
    private func engineRow(_ engine: TranslationEngineChoice) -> some View {
        let isDefault = configuration.engine == engine
        let enabled = configuration.isEnabled(engine)
        let configurable = engine == .ai || engine == .deepl
        let open = configurable && expanded.contains(engine)
        let title = V2L(TranslationWorkspaceView.engineTitle(engine))
        let list = configuration.sortableEngines
        return HStack(spacing: 10) {
            Toggle(title, isOn: Binding(get: { enabled }, set: { configuration.setEnabled(engine, $0) }))
                .labelsHidden().toggleStyle(.checkbox).disabled(engine == .system || isDefault)
            TranslationEngineIcon(engine: engine, size: 18).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(V2L(Self.note(engine))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if configurable { configureButton(engine, open: open, title: title) }
            if isDefault {
                Text(V2L("默认")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).frame(height: 20).background(Color(nsColor: .quaternarySystemFill), in: Capsule())
            } else {
                Image(systemName: "line.3.horizontal").font(.system(size: 13, weight: .medium)).foregroundStyle(.tertiary)
                    .frame(width: 24, height: 28).contentShape(Rectangle())
                    .help(V2L("拖动调整顺序")).accessibilityHidden(true)
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
            if !isDefault, list.first != engine { Button(V2L("上移") + " " + title) { configuration.move(engine, by: -1) } }
            if !isDefault, list.last != engine { Button(V2L("下移") + " " + title) { configuration.move(engine, by: 1) } }
        }
    }
    /// An open engine's settings are ordinary form rows right under it, indented past the checkbox.
    @ViewBuilder private func configurationRows(_ engine: TranslationEngineChoice) -> some View {
        if (engine == .ai || engine == .deepl) && expanded.contains(engine) {
            Group { if engine == .ai { aiConfiguration } else { deeplConfiguration } }
                .padding(.leading, 32)
        }
    }
    /// A pill that reads as a button at rest and turns accent-tinted while its panel is open.
    private func configureButton(_ engine: TranslationEngineChoice, open: Bool, title: String) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { if open { expanded.remove(engine) } else { expanded.insert(engine) } }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .medium))
                Text(V2L("配置")).font(.caption.weight(.medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 180 : 0))
            }
            .foregroundStyle(open ? Color.accentColor : Color.primary)
            .padding(.horizontal, 10).frame(height: 24)
            .background(open ? Color.accentColor.opacity(0.15) : Color(nsColor: .quaternarySystemFill), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(V2L(open ? "收起配置" : "展开配置"))
        .accessibilityLabel(V2L("配置") + " " + title).accessibilityValue(V2L(open ? "已展开" : "已收起"))
    }
    @ViewBuilder private var aiConfiguration: some View {
        Picker(V2L("提供商"), selection: $configuration.provider) { ForEach(TranslationAIProvider.allCases) { Text(V2L($0.title)).tag($0) } }
        TextField(V2L("服务地址"), text: $configuration.endpoint, prompt: Text(verbatim: "https://example.com/v1")).disabled(configuration.provider == .openAI)
            .help(V2L("本机 HTTP 仅支持 localhost、127.0.0.1 或 ::1"))
        LabeledContent(V2L("模型")) {
            HStack(spacing: 0) {
                TextField(V2L("模型"), text: $configuration.model)
                    .labelsHidden().textFieldStyle(.plain).focused($modelFieldFocused)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 8).frame(maxWidth: .infinity)
                Divider().frame(height: 16)
                Button { showsModelPicker.toggle() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showsModelPicker ? 180 : 0))
                        .foregroundStyle(showsModelPicker ? Color.accentColor : Color.secondary)
                        .frame(width: 28, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(V2L("从已获取的模型中选择"))
                .accessibilityLabel(V2L("选择模型"))
                .accessibilityValue(V2L(showsModelPicker ? "已展开" : "已收起"))
                .accessibilityIdentifier("translation.model-list")
            }
            .frame(height: 24)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(modelFieldFocused || showsModelPicker ? Color.accentColor.opacity(0.8) : Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .popover(isPresented: $showsModelPicker, arrowEdge: .bottom) {
                TranslationModelPicker(models: configuration.models, selection: $configuration.model, isPresented: $showsModelPicker)
            }
            .onChange(of: configuration.models) { _, models in
                showsModelPicker = !models.isEmpty
            }
            .onChange(of: configuration.feedback(for: .models)) { _, feedback in
                if case .success? = feedback, !configuration.models.isEmpty { showsModelPicker = true }
            }
            .onDisappear { showsModelPicker = false }
        }
        SecureField(V2L("API Key"), text: $configuration.credential, prompt: Text(V2L("保存在 macOS 钥匙串")))
        HStack(spacing: 8) {
            Spacer()
            settingsActionButton(.models, idle: "获取模型", running: "获取中…", success: "获取成功", failure: "获取失败",
                                 help: "向当前服务地址请求模型列表，不发送原文、截图或剪贴板。", identifier: "translation.fetch-models")
            settingsActionButton(.connection, idle: "测试连接", running: "测试中…", success: "连接成功", failure: "连接失败",
                                 help: "请求当前服务的模型列表，不发送原文、截图或剪贴板。", identifier: "translation.test-connection")
        }
    }
    @ViewBuilder private func settingsActionButton(_ action: TranslationAIAction, idle: String, running: String, success: String, failure: String, help: String, identifier: String) -> some View {
        let feedback = configuration.feedback(for: action)
        let failureMessage: String? = if case .failure(let message)? = feedback { message } else { nil }
        Button {
            if action == .models { modelFieldFocused = true }
            configuration.runSettingsAction(action)
        } label: {
            HStack(spacing: 5) {
                if configuration.isRunning(action) {
                    ProgressView().controlSize(.small)
                    Text(V2L(running))
                } else if case .success? = feedback {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(V2L(success))
                } else if failureMessage != nil {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(V2L(failure))
                } else {
                    Text(V2L(idle))
                }
            }.frame(minWidth: 82)
        }
        .disabled(configuration.isBusy)
        .help(V2L(failureMessage ?? help))
        .accessibilityIdentifier(identifier)
        .accessibilityValue(V2L(failureMessage ?? (feedback == .success ? success : configuration.isRunning(action) ? running : idle)))
    }
    @ViewBuilder private var deeplConfiguration: some View {
        SecureField(V2L("API Key"), text: $configuration.deeplKey, prompt: Text(V2L("保存在 macOS 钥匙串")))
        HStack {
            Spacer()
            settingsActionButton(.deeplTranslate, idle: "测试连接", running: "测试中…", success: "连接成功", failure: "连接失败",
                                 help: "发送固定短句 Hello. 测试连接，不发送原文、截图或剪贴板。", identifier: "translation.test-deepl")
                .disabled(configuration.isBusy || configuration.deeplKey.isEmpty)
        }
    }
    private static func note(_ engine: TranslationEngineChoice) -> String {
        switch engine {
        case .system: "本机翻译，无需联网"
        case .ai, .deepl: "需 API Key"
        case .google, .myMemory: "免费，无需密钥"
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
                Text(V2L("选择模型")).font(.headline)
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
                    Text(V2L("尚未获取模型")).font(.callout).foregroundStyle(.secondary)
                    Text(V2L("先点击“获取模型”获取可用模型列表。")).font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 88)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(V2L("搜索模型"), text: $query, prompt: Text(V2L("输入模型名称筛选")))
                        .labelsHidden().textFieldStyle(.plain).focused($searchFocused)
                    if !query.isEmpty {
                        Button { query = ""; searchFocused = true } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).help(V2L("清除搜索")).accessibilityLabel(V2L("清除搜索"))
                    }
                }
                .padding(.horizontal, 8).frame(height: 28)
                .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 10).padding(.bottom, 8)
                Divider()
                if matches.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(.tertiary)
                        Text(V2L("没有匹配的模型")).font(.callout).foregroundStyle(.secondary)
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
        .accessibilityValue(V2L(selected ? "已选择" : "未选择"))
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
