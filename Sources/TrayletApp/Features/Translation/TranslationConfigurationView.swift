import SwiftUI
import TrayletCore

struct TranslationConfigurationView: View {
    @ObservedObject var configuration: TranslationConfiguration
    @ObservedObject private var localization = V2Localization.shared
    @State private var modelSearch = ""
    @State private var showsStorageRecovery = false
    @State private var expanded: Set<TranslationEngineChoice>
    @State private var dragging: TranslationEngineChoice?
    init(configuration: TranslationConfiguration, expanded: Set<TranslationEngineChoice> = []) {
        self.configuration = configuration
        _expanded = State(initialValue: expanded)
    }
    var body: some View {
        Form {
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
            Section(V2L("翻译引擎")) {
                engineRow(configuration.engine)
                configurationRows(configuration.engine)
                ForEach(configuration.sortableEngines) { engine in
                    engineRow(engine)
                        .onDrop(of: [.text], delegate: EngineDropDelegate(target: engine, configuration: configuration, dragging: $dragging))
                    configurationRows(engine)
                }
            }
            if configuration.isBusy || !configuration.status.isEmpty || configuration.storageIssue != nil || configuration.storageRecoveryNotice != nil {
                Section {
                    if configuration.isBusy { HStack { ProgressView().controlSize(.small); Text(V2L("正在访问已确认的服务…")); Spacer(); Button(V2L("取消")) { configuration.cancel() } } }
                    if !configuration.status.isEmpty { Label(configuration.localizedStatus, systemImage: "info.circle").textSelection(.enabled) }
                    if let issue = configuration.storageIssue {
                        Label(V2L(issue), systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        Button(V2L("备份并恢复默认配置")) { configuration.requestStorageRecovery(); showsStorageRecovery = configuration.storageRecoveryRequested }
                    }
                    if let notice = configuration.storageRecoveryNotice { Text(configuration.localizedStorageRecoveryNotice ?? notice).textSelection(.enabled) }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: Binding(get: { configuration.preview }, set: { if $0 == nil && configuration.preview != nil { configuration.cancel() } })) { request in
            TranslationSendPreview(request: request, cancel: configuration.cancel) { configuration.startConfirmed(request) }
        }
        .onDisappear { configuration.cancel() }
        .alert(V2L("备份并恢复默认配置？"), isPresented: $showsStorageRecovery) {
            Button(V2L("取消"), role: .cancel) { configuration.cancelStorageRecovery() }
            Button(V2L("备份并恢复")) { configuration.confirmStorageRecovery() }
        } message: {
            Text(V2L("将保留当前 v2 配置文件的独立备份，恢复系统翻译默认值，并清除本次内存中的 API Key。不会读取或修改旧版本配置、钥匙串或其他数据。"))
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
        TextField(V2L("模型"), text: $configuration.model)
        SecureField(V2L("API Key"), text: $configuration.credential, prompt: Text(V2L("仅保存在内存，退出后清除")))
        HStack {
            Spacer()
            Button(V2L("获取模型")) { configuration.request(.models) }
            Button(V2L("测试连接")) { configuration.request(.connection) }
            Button(V2L("固定短文测试")) { configuration.request(.modelTest) }
        }.disabled(configuration.isBusy)
        if !configuration.models.isEmpty {
            let matches = configuration.models.filter { modelSearch.isEmpty || $0.localizedCaseInsensitiveContains(modelSearch) }
            TextField(V2L("搜索模型"), text: $modelSearch, prompt: Text(V2L("搜索模型"))).labelsHidden().textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(matches, id: \.self) { model in
                        Button { configuration.model = model } label: { HStack { Text(model).lineLimit(2); Spacer(); if configuration.model == model { Image(systemName: "checkmark") } } }.buttonStyle(.borderless).padding(4)
                    }
                }
            }.frame(height: min(CGFloat(matches.count) * 30, 150))
        }
    }
    @ViewBuilder private var deeplConfiguration: some View {
        SecureField(V2L("API Key"), text: $configuration.deeplKey, prompt: Text(V2L("仅保存在内存，退出后清除")))
        HStack {
            Spacer()
            Button(V2L("测试连接")) { configuration.request(.deeplTranslate) }.disabled(configuration.isBusy || configuration.deeplKey.isEmpty)
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
