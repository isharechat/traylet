import AppKit
import SwiftUI
import TrayletCore

struct OCRConfigurationView: View {
    @ObservedObject var configuration: OCRConfiguration
    @ObservedObject private var localization = Localization.shared
    @State private var showsStorageRecovery = false
    @State private var showsModelPicker = false
    @State private var endpointDraft: String
    @State private var modelDraft: String
    @State private var credentialDraft: String
    @State private var promptDraft: String
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var modelFieldFocused: Bool

    init(configuration: OCRConfiguration) {
        self.configuration = configuration
        _endpointDraft = State(initialValue: configuration.endpoint)
        _modelDraft = State(initialValue: configuration.model)
        _credentialDraft = State(initialValue: configuration.credential)
        _promptDraft = State(initialValue: configuration.customPrompt)
    }

    var body: some View {
        Form {
            Section(L("识别与后处理")) {
                Picker(L("默认识别引擎"), selection: $configuration.defaultEngine) {
                    ForEach(OCREngineChoice.allCases) { engine in
                        Text(L(engine.title)).tag(engine)
                    }
                }
                Toggle(L("识别后自动复制到剪贴板"), isOn: $configuration.autoCopy)
                Toggle(L("默认合并换行"), isOn: $configuration.mergeLineBreaks)
                Toggle(L("本机 Vision 高精度识别"), isOn: $configuration.visionAccurate)
            }
            .toggleStyle(.switch)

            Section {
                Picker(L("服务商"), selection: $configuration.provider) {
                    ForEach(TranslationAIProvider.allCases) { item in
                        Text(L(item.title)).tag(item)
                    }
                }
                if configuration.provider == .compatible {
                    LabeledContent(L("接口地址")) {
                        TextField("http://127.0.0.1:1234/v1", text: $endpointDraft)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: endpointDraft) { _, value in scheduleSave { configuration.endpoint = value } }
                    }
                }
                LabeledContent("API Key") {
                    SecureField(L("留空表示本机无需密钥"), text: $credentialDraft)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: credentialDraft) { _, value in scheduleSave { configuration.credential = value } }
                }

                LabeledContent(L("视觉模型")) {
                    HStack(spacing: 4) {
                        TextField(L("如 gpt-4o / qwen-vl-plus"), text: $modelDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($modelFieldFocused)
                        .onChange(of: modelDraft) { _, value in scheduleSave { configuration.model = value } }

                        Button { showsModelPicker.toggle() } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help(L("选择已获取的模型"))
                        .popover(isPresented: $showsModelPicker, arrowEdge: .bottom) {
                            modelPickerPopover
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        flushDrafts()
                        configuration.runSettingsAction(.models)
                        modelFieldFocused = true
                    } label: {
                        HStack(spacing: 6) {
                            if configuration.isRunning(.models) { ProgressView().controlSize(.mini) }
                            Text(L("获取模型"))
                        }
                    }
                    .disabled(configuration.isBusy)

                    Button {
                        flushDrafts()
                        configuration.runSettingsAction(.connection)
                    } label: {
                        HStack(spacing: 6) {
                            if configuration.isRunning(.connection) { ProgressView().controlSize(.mini) }
                            Text(L("测试连接"))
                        }
                    }
                    .disabled(configuration.isBusy)

                    Spacer()
                    feedbackLabel(configuration.feedback(for: .models) ?? configuration.feedback(for: .connection))
                }
            } header: {
                Text(L("AI OCR 服务"))
            } footer: {
                Text(L("AI OCR 使用支持图像输入的视觉模型；仅在主动切换 AI 识别或点击重试时发送当前图片。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)

            Section(L("AI 识别提示词")) {
                Picker(L("默认模式"), selection: $configuration.preset) {
                    ForEach(OCRAIPreset.allCases) { preset in
                        Text(L(preset.title)).tag(preset)
                    }
                }
                if configuration.preset == .custom {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("自定义提示词"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $promptDraft)
                            .font(.callout)
                            .frame(minHeight: 72, maxHeight: 120)
                            .padding(4)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Design.Radius.control))
                            .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).stroke(Color(nsColor: .separatorColor).opacity(0.4)))
                            .onChange(of: promptDraft) { _, value in scheduleSave { configuration.customPrompt = value } }
                        Button(L("恢复默认提示词")) {
                            promptDraft = OCRAIPreset.plainText.systemPrompt
                            configuration.customPrompt = promptDraft
                        }
                        .controlSize(.small)
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

    private var modelPickerPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            if configuration.models.isEmpty {
                Text(L("请先点击“获取模型”或手动输入模型名称。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(configuration.models, id: \.self) { item in
                            Button {
                                modelDraft = item
                                configuration.model = item
                                showsModelPicker = false
                            } label: {
                                HStack {
                                    Text(item).lineLimit(1)
                                    Spacer()
                                    if item == modelDraft { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                }
                .frame(width: 260, height: min(CGFloat(configuration.models.count) * 28 + 16, 240))
            }
        }
    }

    @ViewBuilder
    private func feedbackLabel(_ feedback: TranslationActionFeedback?) -> some View {
        switch feedback {
        case .success:
            Label(L("成功"), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let message):
            Text(L(message))
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        case nil:
            EmptyView()
        }
    }

    private func scheduleSave(_ apply: @escaping @MainActor () -> Void) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            apply()
        }
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
