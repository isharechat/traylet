import Foundation
import Combine
import TrayletCore

@MainActor final class OCRConfiguration: ObservableObject {
    @Published var defaultEngine: OCREngineChoice = .vision { didSet { if defaultEngine != oldValue { changed(clearModels: false) } } }
    @Published var autoCopy = false { didSet { if autoCopy != oldValue { changed(clearModels: false) } } }
    @Published var mergeLineBreaks = false { didSet { if mergeLineBreaks != oldValue { changed(clearModels: false) } } }
    @Published var visionAccurate = true { didSet { if visionAccurate != oldValue { changed(clearModels: false) } } }
    @Published var provider: TranslationAIProvider = .compatible {
        didSet {
            guard provider != oldValue else { return }
            if provider == .openAI { endpoint = "https://api.openai.com/v1" }
            changed()
        }
    }
    @Published var endpoint = "http://127.0.0.1:1234/v1" { didSet { if endpoint != oldValue { changed() } } }
    @Published var model = "" { didSet { if model != oldValue { changed(clearModels: false) } } }
    @Published var credential = "" { didSet { if credential != oldValue { changed(clearModels: false) } } }
    @Published var preset: OCRAIPreset = .plainText { didSet { if preset != oldValue { changed(clearModels: false) } } }
    @Published var customPrompt = "" { didSet { if customPrompt != oldValue { changed(clearModels: false) } } }

    @Published private(set) var models: [String] = []
    @Published private(set) var isBusy = false
    @Published private(set) var runningAction: TranslationAIAction?
    @Published private(set) var actionFeedback: [TranslationAIAction: TranslationActionFeedback] = [:]
    @Published private(set) var storageIssue: String?
    @Published private(set) var storageRecoveryRequested = false
    @Published private(set) var storageRecoveryNotice: String?

    let client: any TranslationAIClient
    private let storageURL: URL?
    private let credentialStore: (any OCRCredentialStoring)?
    private var lastPersistedCredential = ""
    private var operationID: UUID?
    private var task: Task<Void, Never>?
    private var loading = true
    private var recoveryBackupPath: String?
    private var lastSaved: Data?

    private struct Saved: Codable {
        let version: Int
        var defaultEngine: OCREngineChoice
        var autoCopy: Bool
        var mergeLineBreaks: Bool
        var visionAccurate: Bool
        var provider: TranslationAIProvider
        var endpoint: String
        var model: String
        var preset: OCRAIPreset
        var customPrompt: String
    }

    init(
        storageURL: URL? = nil,
        client: any TranslationAIClient = TranslationOpenAIClient(),
        credentialStore: (any OCRCredentialStoring)? = nil
    ) {
        self.storageURL = storageURL
        self.client = client
        self.credentialStore = credentialStore
        if let storageURL {
            do {
                if let data = try TranslationConfigurationStore(url: storageURL).read() {
                    let saved = try JSONDecoder().decode(Saved.self, from: data)
                    guard saved.version == 1 else { throw TranslationAIFailure.malformed }
                    defaultEngine = saved.defaultEngine
                    autoCopy = saved.autoCopy
                    mergeLineBreaks = saved.mergeLineBreaks
                    visionAccurate = saved.visionAccurate
                    provider = saved.provider
                    endpoint = saved.endpoint
                    model = saved.model
                    preset = saved.preset
                    customPrompt = saved.customPrompt
                    lastSaved = data
                }
            } catch {
                storageIssue = "新版本 OCR 设置无法读取；当前使用默认值，原文件保留。"
            }
        }
        if let credentialStore {
            credential = credentialStore.read() ?? ""
            lastPersistedCredential = credential
        }
        loading = false
    }

    var ownAISettings: TranslationAISettings {
        TranslationAISettings(
            endpoint: provider == .openAI ? "https://api.openai.com/v1" : endpoint,
            model: model,
            credential: credential
        )
    }

    var effectiveSettings: TranslationAISettings {
        ownAISettings
    }

    func effectivePrompt(for preset: OCRAIPreset) -> String {
        if preset == .custom {
            let trimmed = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? OCRAIPreset.plainText.systemPrompt : trimmed
        }
        return preset.systemPrompt
    }

    var localizedStorageRecoveryNotice: String? {
        guard let storageRecoveryNotice else { return nil }
        if let recoveryBackupPath { return String(format: L("已恢复默认配置，原文件备份：%@"), recoveryBackupPath) }
        return L(storageRecoveryNotice)
    }

    func feedback(for action: TranslationAIAction) -> TranslationActionFeedback? { actionFeedback[action] }
    func isRunning(_ action: TranslationAIAction) -> Bool { runningAction == action }

    func runSettingsAction(_ action: TranslationAIAction) {
        guard action == .models || action == .connection else { return }
        cancel()
        task = Task { [weak self] in await self?.performSettingsAction(action) }
    }

    func performSettingsAction(_ action: TranslationAIAction) async {
        guard action == .models || action == .connection, !isBusy else { return }
        let used = effectiveSettings
        do {
            _ = try used.url(for: action)
        } catch {
            actionFeedback = [action: .failure(TranslationAIFailure.safeMessage(error))]
            return
        }
        let request = TranslationAIRequest(id: UUID(), action: action, settings: used, content: "", source: "auto", target: "zh-Hans")
        actionFeedback = [:]
        runningAction = action
        operationID = request.id
        isBusy = true
        do {
            let result = try await client.perform(request)
            guard operationID == request.id, request.settings == effectiveSettings, !Task.isCancelled else { return }
            switch result {
            case .models(let items):
                models = items
                actionFeedback[.models] = items.isEmpty ? .failure("服务返回空模型列表；可手动填写。") : .success
            case .connected:
                actionFeedback[.connection] = .success
            case .text:
                actionFeedback[action] = .success
            }
        } catch {
            guard operationID == request.id else { return }
            actionFeedback[action] = .failure(TranslationAIFailure.safeMessage(error))
        }
        if operationID == request.id { operationID = nil; isBusy = false; runningAction = nil }
    }

    func cancel() {
        task?.cancel()
        task = nil
        operationID = nil
        isBusy = false
        runningAction = nil
        actionFeedback = [:]
        storageRecoveryRequested = false
    }

    func requestStorageRecovery() {
        guard storageURL != nil, storageIssue != nil else { return }
        cancel()
        storageRecoveryRequested = true
    }

    func cancelStorageRecovery() { storageRecoveryRequested = false }

    func confirmStorageRecovery() {
        guard storageRecoveryRequested, let storageURL, storageIssue != nil else { return }
        cancel()
        lastSaved = nil
        loading = true
        credential = ""
        loading = false
        credentialStore?.remove()
        lastPersistedCredential = ""
        models = []
        do {
            let defaults = Saved(
                version: 1,
                defaultEngine: .vision,
                autoCopy: false,
                mergeLineBreaks: false,
                visionAccurate: true,
                provider: .compatible,
                endpoint: "http://127.0.0.1:1234/v1",
                model: "",
                preset: .plainText,
                customPrompt: ""
            )
            let backup = try TranslationConfigurationStore(url: storageURL).write(JSONEncoder().encode(defaults), preservingOriginal: true)
            loading = true
            defaultEngine = defaults.defaultEngine
            autoCopy = defaults.autoCopy
            mergeLineBreaks = defaults.mergeLineBreaks
            visionAccurate = defaults.visionAccurate
            provider = defaults.provider
            endpoint = defaults.endpoint
            model = defaults.model
            preset = defaults.preset
            customPrompt = defaults.customPrompt
            loading = false
            storageIssue = nil
            recoveryBackupPath = backup?.path
            storageRecoveryNotice = backup.map { "已恢复默认配置，原文件备份：\($0.path)" } ?? "已重建默认配置。"
        } catch {
            storageIssue = "恢复失败；原文件或同目录备份已保留。请检查目录权限及符号链接后重试。内存凭据已清除。"
            storageRecoveryNotice = nil
            recoveryBackupPath = nil
        }
    }

    private func changed(clearModels: Bool = true) {
        guard !loading else { return }
        if let credentialStore, credential != lastPersistedCredential {
            credentialStore.write(credential)
            lastPersistedCredential = credential
        }
        cancel()
        if clearModels { models = [] }
        guard let storageURL, storageIssue == nil else { return }
        guard (try? ownAISettings.url(for: .models)) != nil else { return }
        do {
            let value = Saved(
                version: 1,
                defaultEngine: defaultEngine,
                autoCopy: autoCopy,
                mergeLineBreaks: mergeLineBreaks,
                visionAccurate: visionAccurate,
                provider: provider,
                endpoint: endpoint,
                model: model,
                preset: preset,
                customPrompt: customPrompt
            )
            let data = try JSONEncoder().encode(value)
            guard data != lastSaved else { return }
            try TranslationConfigurationStore(url: storageURL).write(data)
            lastSaved = data
        } catch {
            storageIssue = "OCR 设置保存失败；当前更改仅保留在内存。"
        }
    }
}
