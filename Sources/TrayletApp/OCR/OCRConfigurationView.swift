import AppKit
import SwiftUI
import TrayletCore

struct OCRConfigurationView: View {
    @ObservedObject var configuration: OCRConfiguration
    @ObservedObject private var localization = Localization.shared
    @State private var showsStorageRecovery = false
    @State private var showsModelPicker = false
    @State private var aiExpanded: Bool
    @State private var endpointDraft: String
    @State private var modelDraft: String
    @State private var credentialDraft: String
    @State private var promptDraft: String
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var modelFieldFocused: Bool

    init(configuration: OCRConfiguration, aiExpanded: Bool = false) {
        self.configuration = configuration
        _aiExpanded = State(initialValue: aiExpanded)
        _endpointDraft = State(initialValue: configuration.endpoint)
        _modelDraft = State(initialValue: configuration.model)
        _credentialDraft = State(initialValue: configuration.credential)
        _promptDraft = State(initialValue: configuration.customPrompt)
    }

    private var orderedEngines: [OCREngineChoice] {
        [configuration.defaultEngine] + OCREngineChoice.allCases.filter { $0 != configuration.defaultEngine }
    }

    var body: some View {
        Form {
            Section(L("识别与后处理")) {
                Toggle(L("识别后自动复制到剪贴板"), isOn: $configuration.autoCopy)
                Toggle(L("默认合并换行"), isOn: $configuration.mergeLineBreaks)
                Toggle(L("本机 Vision 高精度识别"), isOn: $configuration.visionAccurate)
            }
            .toggleStyle(.switch)

            Section(L("OCR 引擎")) {
                ForEach(orderedEngines) { engine in
                    engineRow(engine)
                    if engine == .ai && aiExpanded {
                        aiConfiguration
                            .padding(.leading, 32)
                    }
                }
            }

            if configuration.storageIssue != nil || configuration.storageRecoveryNotice != nil {
                Section {
                    if let issue = configuration.storageIssue {
                        Label(L(issue), systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        Button(L("备份并恢复默认配置")) {
                            configuration.requestStorageRecovery()
                            showsStorageRecovery = configuration.storageRecoveryRequested
                        }
                    }
                    if let notice = configuration.storageRecoveryNotice {
                        Text(configuration.localizedStorageRecoveryNotice ?? notice).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { flushDrafts(); configuration.cancel() }
        .onChange(of: configuration.endpoint) { _, value in if endpointDraft != value { endpointDraft = value } }
        .onChange(of: configuration.model) { _, value in if modelDraft != value { modelDraft = value } }
        .onChange(of: configuration.credential) { _, value in if credentialDraft != value { credentialDraft = value } }
        .onChange(of: configuration.customPrompt) { _, value in if promptDraft != value { promptDraft = value } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            flushDrafts()
        }
        .alert(L("备份并恢复默认配置？"), isPresented: $showsStorageRecovery) {
            Button(L("取消"), role: .cancel) { configuration.cancelStorageRecovery() }
            Button(L("备份并恢复")) { configuration.confirmStorageRecovery() }
        } message: {
            Text(L("将保留当前 v2 配置文件的独立备份，恢复默认 OCR 设置，并清除钥匙串中的 OCR API Key。"))
        }
    }

    private func engineRow(_ engine: OCREngineChoice) -> some View {
        let isDefault = configuration.defaultEngine == engine
        let title = L(engine.title)
        return HStack(spacing: 10) {
            engineIcon(engine)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                StatusPill(
                    text: L(engine == .vision ? "本机 · 离线" : "需密钥"),
                    tint: engine == .vision ? .green : .accentColor
                )
            }
            Spacer(minLength: 8)
            if engine == .ai {
                EngineConfigureButton(open: aiExpanded, title: title) {
                    withAnimation(Design.Animation.snappy) { aiExpanded.toggle() }
                }
            }
            EngineDefaultControl(isDefault: isDefault, title: title) {
                configuration.defaultEngine = engine
            }
        }
        .frame(minHeight: 36)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func engineIcon(_ engine: OCREngineChoice) -> some View {
        switch engine {
        case .vision:
            Image(systemName: "text.viewfinder")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.green)
        case .ai:
            TranslationEngineIcon(engine: .ai, size: 18)
        }
    }

    @ViewBuilder
    private var aiConfiguration: some View {
        Picker(L("提供商"), selection: $configuration.provider) {
            ForEach(TranslationAIProvider.allCases) { Text(L($0.title)).tag($0) }
        }
        TextField(L("服务地址"), text: debouncedBinding($endpointDraft), prompt: Text(verbatim: "https://example.com/v1"))
            .disabled(configuration.provider == .openAI)
            .onSubmit { flushDrafts() }
            .help(L("本机 HTTP 仅支持 localhost、127.0.0.1 或 ::1"))
        AIModelComboField(
            model: debouncedBinding($modelDraft),
            models: configuration.models,
            showsPicker: $showsModelPicker,
            focused: $modelFieldFocused,
            identifier: "ocr.model-list",
            onCommit: flushDrafts
        )
        .onChange(of: configuration.models) { _, models in
            showsModelPicker = !models.isEmpty
        }
        .onChange(of: configuration.feedback(for: .models)) { _, feedback in
            if case .success? = feedback, !configuration.models.isEmpty { showsModelPicker = true }
        }
        SecureField(L("API Key"), text: debouncedBinding($credentialDraft), prompt: Text(L("保存在 macOS 钥匙串")))
            .onSubmit { flushDrafts() }
        Picker(L("默认模式"), selection: $configuration.preset) {
            ForEach(OCRAIPreset.allCases) { preset in
                Text(L(preset.title)).tag(preset)
            }
        }
        if configuration.preset == .custom {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("自定义提示词")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !promptDraft.isEmpty {
                        Button(L("恢复默认提示词")) {
                            promptDraft = ""
                            configuration.customPrompt = ""
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                    }
                }
                PromptTextEditor(text: debouncedBinding($promptDraft), placeholder: L("留空使用默认提示词"))
            }
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
                identifier: "ocr.fetch-models"
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
                identifier: "ocr.test-connection"
            ) {
                flushDrafts()
                configuration.runSettingsAction(.connection)
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
        debounceTask?.cancel()
        debounceTask = nil
        if configuration.endpoint != endpointDraft { configuration.endpoint = endpointDraft }
        if configuration.model != modelDraft { configuration.model = modelDraft }
        if configuration.credential != credentialDraft { configuration.credential = credentialDraft }
        if configuration.customPrompt != promptDraft { configuration.customPrompt = promptDraft }
    }
}
