import Foundation
import Combine
import TrayletCore

@MainActor final class TranslationConfiguration: ObservableObject {
    /// Engines are configured side by side. The default engine always comes first in the window; the others follow `order`.
    @Published var engine: TranslationEngineChoice = .system {
        didSet { if !enabled.contains(engine) { enabled.insert(engine) }; changed() }
    }
    /// Engines shown in the translation window. System translation is always included.
    @Published private(set) var enabled: Set<TranslationEngineChoice> = [.system] {
        didSet { if !enabled.contains(engine) { engine = .system }; changed() }
    }
    @Published private(set) var order = TranslationConfiguration.defaultOrder { didSet { changed() } }
    /// Most engine icons the window shows; it is sized so they all fit even at its smallest width.
    @Published var maxVisible = 4 { didSet { if !(Self.visibleRange ~= maxVisible) { maxVisible = min(max(maxVisible, Self.visibleRange.lowerBound), Self.visibleRange.upperBound); return }; changed() } }
    static let defaultOrder: [TranslationEngineChoice] = [.system, .ai, .deepl, .google, .myMemory]
    static let visibleRange = 1...6
    var aiEnabled: Bool { get { enabled.contains(.ai) } set { setEnabled(.ai, newValue) } }
    var deeplEnabled: Bool { get { enabled.contains(.deepl) } set { setEnabled(.deepl, newValue) } }
    func isEnabled(_ engine: TranslationEngineChoice) -> Bool { enabled.contains(engine) }
    func setEnabled(_ engine: TranslationEngineChoice, _ on: Bool) {
        guard engine != .system else { return }
        if on { enabled.insert(engine) } else { enabled.remove(engine) }
    }
    /// Every engine except the pinned default, checked or not, in the saved order.
    var sortableEngines: [TranslationEngineChoice] { order.filter { $0 != engine } }
    func move(_ engine: TranslationEngineChoice, by offset: Int) {
        let list = sortableEngines
        guard offset != 0, let index = list.firstIndex(of: engine), list.indices.contains(index + offset) else { return }
        move(engine, to: list[index + offset])
    }
    /// Places `engine` where `target` is, shifting `target` away; used live while dragging.
    func move(_ engine: TranslationEngineChoice, to target: TranslationEngineChoice) {
        guard engine != target, engine != self.engine, target != self.engine,
              let from = order.firstIndex(of: engine), let to = order.firstIndex(of: target) else { return }
        var next = order
        next.remove(at: from)
        next.insert(engine, at: to)
        order = next
    }
    /// Default engine first, then the other enabled engines in the saved order.
    var availableEngines: [TranslationEngineChoice] { [engine] + order.filter { $0 != engine && enabled.contains($0) } }
    var visibleEngines: [TranslationEngineChoice] { Array(availableEngines.prefix(maxVisible)) }
    @Published var deeplKey = "" { didSet { changed() } }
    @Published var provider: TranslationAIProvider = .compatible { didSet { if provider == .openAI { endpoint = "https://api.openai.com/v1" }; changed() } }
    @Published var endpoint = "http://127.0.0.1:1234/v1" { didSet { changed() } }
    @Published var model = "" { didSet { changed(clearModels: false) } }
    @Published var credential = "" { didSet { changed() } }
    @Published private(set) var revision = UUID()
    @Published private(set) var models: [String] = []
    @Published private(set) var preview: TranslationAIRequest?
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""
    @Published private(set) var storageIssue: String?
    @Published private(set) var storageRecoveryRequested = false
    @Published private(set) var storageRecoveryNotice: String?
    let client: any TranslationAIClient
    private let storageURL: URL?
    private var operationID: UUID?
    private var task: Task<Void, Never>?
    private var loading = true
    private enum StatusDetails { case models(Int), test(String) }
    private var statusDetails: StatusDetails?
    private var recoveryBackupPath: String?
    private var lastSaved: Data?
    private struct Saved: Codable {
        let version: Int; let engine: TranslationEngineChoice; let provider: TranslationAIProvider; let endpoint: String; let model: String
        // Added with multi-engine support; files written before it decode with these absent.
        var aiEnabled: Bool? = nil; var deeplEnabled: Bool? = nil
        var enabled: [TranslationEngineChoice]? = nil; var order: [TranslationEngineChoice]? = nil; var maxVisible: Int? = nil
    }
    init(storageURL: URL? = nil, client: any TranslationAIClient = TranslationOpenAIClient()) {
        self.storageURL = storageURL; self.client = client
        if let storageURL {
            do {
                if let data = try TranslationConfigurationStore(url: storageURL).read() {
                let saved = try JSONDecoder().decode(Saved.self, from: data)
                guard saved.version == 2 else { throw TranslationAIFailure.malformed }
                provider = saved.provider; endpoint = saved.endpoint; model = saved.model
                // Older files only had the AI and DeepL switches; the selected engine always stays enabled.
                var on: Set<TranslationEngineChoice> = Set(saved.enabled ?? []).union([.system])
                if saved.enabled == nil {
                    if saved.aiEnabled ?? (saved.engine == .ai) { on.insert(.ai) }
                    if saved.deeplEnabled ?? (saved.engine == .deepl) { on.insert(.deepl) }
                }
                enabled = on
                engine = saved.engine
                if let saved = saved.order { order = saved + Self.defaultOrder.filter { !saved.contains($0) } }
                maxVisible = saved.maxVisible ?? maxVisible
                }
            } catch { storageIssue = "新版本翻译设置无法读取；当前使用默认值，原文件保留。" }
        }
        loading = false
    }
    var settings: TranslationAISettings { .init(endpoint: provider == .openAI ? "https://api.openai.com/v1" : endpoint, model: model, credential: credential) }
    var deeplSettings: TranslationAISettings { .init(endpoint: TranslationDeepLLanguages.endpoint(forKey: deeplKey), model: "", credential: deeplKey) }
    func settings(for engine: TranslationEngineChoice) -> TranslationAISettings {
        switch engine {
        case .deepl: deeplSettings
        case .google: .init(endpoint: "https://translate.googleapis.com", model: "", credential: "")
        case .myMemory: .init(endpoint: "https://api.mymemory.translated.net", model: "", credential: "")
        case .system, .ai: settings
        }
    }
    var localizedStatus: String {
        switch statusDetails {
        case .models(let count): String(format: V2L("已获取 %d 个模型；选择模型不代表已验证翻译能力。"), count)
        case .test(let text): String(format: V2L("固定短文测试结果：\n%@"), text)
        case nil: V2L(status)
        }
    }
    var localizedStorageRecoveryNotice: String? {
        guard let storageRecoveryNotice else { return nil }
        if let recoveryBackupPath { return String(format: V2L("已恢复默认配置，原文件备份：%@"), recoveryBackupPath) }
        return V2L(storageRecoveryNotice)
    }
    func makeRequest(_ action: TranslationAIAction, content: String = "", source: String = "auto", target: String = "zh-Hans") throws -> TranslationAIRequest {
        let used = settings(for: action.engine)
        _ = try used.url(for: action)
        return .init(id: UUID(), action: action, settings: used, content: action == .modelTest ? "Hello." : content, source: action == .modelTest ? "en" : source, target: action == .modelTest ? "zh-Hans" : target)
    }
    func request(_ action: TranslationAIAction) {
        cancel(); statusDetails = nil
        do {
            // The DeepL test sends one fixed short sentence, never the user's own text.
            preview = action == .deeplTranslate ? try makeRequest(.deeplTranslate, content: "Hello.", source: "en", target: "zh-Hans") : try makeRequest(action)
            status = ""
        }
        catch { status = TranslationAIFailure.safeMessage(error) }
    }
    func confirm(_ request: TranslationAIRequest) async {
        guard preview == request, request.settings == settings(for: request.action.engine) else { return }
        preview = nil; operationID = request.id; isBusy = true
        do {
            let result = try await client.perform(request)
            guard operationID == request.id, request.settings == settings(for: request.action.engine), !Task.isCancelled else { return }
            switch result {
            case .models(let items):
                models = items
                statusDetails = items.isEmpty ? nil : .models(items.count)
                status = items.isEmpty ? "服务返回空模型列表；可手动填写。" : "已获取 \(items.count) 个模型；选择模型不代表已验证翻译能力。"
            case .connected: status = "模型列表端点已响应；模型翻译能力尚未验证。"
            case .text(let text):
                // Redact before limiting display length so a cut-off echo cannot reveal a key prefix.
                let secret = request.action == .deeplTranslate ? deeplKey : credential
                let safeText = secret.isEmpty ? text : text.replacingOccurrences(of: secret, with: "[已隐藏]")
                statusDetails = .test(String(safeText.prefix(4096)))
                status = "固定短文测试结果：" + String(safeText.prefix(4096))
            }
        } catch {
            guard operationID == request.id else { return }
            status = TranslationAIFailure.safeMessage(error)
        }
        if operationID == request.id { operationID = nil; isBusy = false }
    }
    func startConfirmed(_ request: TranslationAIRequest) {
        task?.cancel()
        task = Task { [weak self] in await self?.confirm(request) }
    }
    func cancel() { task?.cancel(); task = nil; operationID = nil; preview = nil; isBusy = false; storageRecoveryRequested = false }
    func requestStorageRecovery() {
        guard storageURL != nil, storageIssue != nil else { return }
        cancel(); storageRecoveryRequested = true
    }
    func cancelStorageRecovery() { storageRecoveryRequested = false }
    func confirmStorageRecovery() {
        guard storageRecoveryRequested, let storageURL, storageIssue != nil else { return }
        cancel(); lastSaved = nil
        loading = true
        credential = ""; deeplKey = ""
        loading = false
        models = []; status = ""; statusDetails = nil; revision = UUID()
        do {
            let defaults = Saved(version: 2, engine: .system, provider: .compatible, endpoint: "http://127.0.0.1:1234/v1", model: "")
            let backup = try TranslationConfigurationStore(url: storageURL).write(JSONEncoder().encode(defaults), preservingOriginal: true)
            loading = true
            engine = defaults.engine; provider = defaults.provider; endpoint = defaults.endpoint; model = defaults.model
            enabled = [.system]; order = Self.defaultOrder; maxVisible = 4
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
        cancel(); revision = UUID(); status = ""; statusDetails = nil
        if clearModels { models = [] }
        guard let storageURL, storageIssue == nil else { return }
        // Malformed URLs can contain credentials; never store those as a preference.
        guard (try? settings.url(for: .models)) != nil else { return }
        do {
            let value = Saved(version: 2, engine: engine, provider: provider, endpoint: endpoint, model: model, enabled: Array(enabled), order: order, maxVisible: maxVisible)
            let data = try JSONEncoder().encode(value)
            // Typing an API Key changes nothing on disk; skip the synced write instead of repeating it per keystroke.
            guard data != lastSaved else { return }
            try TranslationConfigurationStore(url: storageURL).write(data)
            lastSaved = data
        } catch { storageIssue = "翻译设置保存失败；当前更改仅保留在内存。" }
    }
}
