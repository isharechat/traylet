import Foundation
import OSLog
import SwiftUI
import Translation

private let languagePackLogger = Logger(subsystem: "local.traylet.app", category: "TranslationLanguagePacks")

enum TranslationLanguagePackState: Equatable {
    case unknown
    case checking
    case installed
    case downloadable
    case unsupported
    case preparing
    case failed(String)
}

enum TranslationLanguagePackDownloadOutcome: Equatable, Sendable {
    case success
    case failure(TranslationSystemSessionFailure)
}

struct TranslationLanguagePackRequest: Equatable, Identifiable, Sendable {
    let id: UUID
    let source: String
    let target: String
}

struct TranslationLanguagePackPair: Equatable, Sendable {
    let source: String
    let target: String
}

@MainActor final class TranslationLanguagePackController: ObservableObject {
    @Published var source = "en" { didSet { if source != oldValue { reset() } } }
    @Published var target = "zh-Hans" { didSet { if target != oldValue { reset() } } }
    @Published private(set) var state = TranslationLanguagePackState.unknown
    @Published private(set) var request: TranslationLanguagePackRequest?
    private let availability: any TranslationResourceChecking
    private var checkTask: Task<Void, Never>?
    private var checkID = UUID()

    init(availability: any TranslationResourceChecking = TranslationSystemResources()) {
        self.availability = availability
    }

    var canDownload: Bool {
        source != target && state != .checking && state != .preparing && state != .installed && state != .unsupported
    }

    func apply(_ pair: TranslationLanguagePackPair) {
        guard source != pair.source || target != pair.target else { return }
        reset()
        source = pair.source
        target = pair.target
    }

    @discardableResult
    func check() -> Task<Void, Never> {
        checkTask?.cancel()
        let id = UUID(), source = source, target = target
        checkID = id
        state = .checking
        let task = Task { @MainActor [weak self, availability] in
            guard source != target else {
                if let self, self.checkID == id { self.state = .failed("请选择不同的原文和目标语言。") }
                return
            }
            do {
                let result = try await availability.status(text: "", source: source, target: target)
                guard !Task.isCancelled, let self, self.checkID == id else { return }
                switch result {
                case .installed: self.state = .installed
                case .downloadable: self.state = .downloadable
                case .unsupported: self.state = .unsupported
                }
            } catch {
                guard !Task.isCancelled, let self, self.checkID == id else { return }
                self.state = .failed("无法检查系统语言资源，请稍后重试。")
            }
        }
        checkTask = task
        return task
    }

    func download() {
        guard source != target else {
            state = .failed("请选择不同的原文和目标语言。")
            return
        }
        guard canDownload else { return }
        checkTask?.cancel(); checkTask = nil
        checkID = UUID()
        request = TranslationLanguagePackRequest(id: UUID(), source: source, target: target)
        state = .preparing
    }

    @discardableResult
    func completeDownload(_ id: UUID, outcome: TranslationLanguagePackDownloadOutcome) -> Task<Void, Never>? {
        guard request?.id == id else { return nil }
        request = nil
        switch outcome {
        case .success:
            return check()
        case .failure(let reason):
            state = .failed(Self.failureMessage(reason))
            return nil
        }
    }

    private static func failureMessage(_ reason: TranslationSystemSessionFailure) -> String {
        switch reason {
        case .notInstalled:
            return "系统未允许下载语言模型。请在“系统设置 → 通用 → 语言与地区”中下载所需语言后重试。"
        case .unsupportedPairing:
            return "系统不支持当前语言对，请更换原文或译文语言。"
        case .unableToIdentifyLanguage:
            return "无法识别原文语言，请选择明确的原文语言后重试。"
        case .unavailable:
            return "语言包下载未完成。请检查网络或系统设置后重试。"
        }
    }

    func cancel() {
        checkTask?.cancel(); checkTask = nil
        checkID = UUID()
        request = nil
        if state == .checking || state == .preparing { state = .unknown }
    }

    private func reset() {
        cancel()
        state = .unknown
    }
}

@MainActor
struct TranslationLanguagePackSettings: View {
    @ObservedObject var controller: TranslationLanguagePackController

    var body: some View {
        Section(V2L("系统语言包")) {
            Picker(V2L("原文语言"), selection: $controller.source) {
                ForEach(languages, id: \.0) { Text(V2L($0.1)).tag($0.0) }
            }
            Picker(V2L("译文语言"), selection: $controller.target) {
                ForEach(languages, id: \.0) { Text(V2L($0.1)).tag($0.0) }
            }
            LabeledContent(V2L("状态")) { status }
            HStack(spacing: 8) {
                Button(V2L("检查状态")) { controller.check() }
                    .disabled(controller.state == .checking || controller.state == .preparing)
                Button { controller.download() } label: {
                    if controller.state == .preparing {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text(V2L("正在下载…"))
                        }
                    } else {
                        Text(V2L("下载语言包"))
                    }
                }
                .disabled(!controller.canDownload)
                Spacer(minLength: 0)
            }
            Text(V2L("仅本机安装，不上传内容。"))
                .font(.caption).foregroundStyle(.secondary)
                .help(V2L("语言包由 macOS 按系统批准流程下载并安装到本机；不会上传原文、截图或剪贴板。"))
        }
        .background {
            if let request = controller.request {
                TranslationLanguagePackHost(request: request) { outcome in
                    _ = controller.completeDownload(request.id, outcome: outcome)
                }
                .id(request.id)
            }
        }
        .onDisappear { controller.cancel() }
    }

    private var languages: [(String, String)] {
        TranslationWorkspaceView.languages.filter { $0.0 != "auto" }
    }

    @ViewBuilder private var status: some View {
        switch controller.state {
        case .unknown: Text(V2L("尚未检查")).foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text(V2L("正在检查…"))
            }
        case .installed: Label(V2L("已安装"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloadable: Label(V2L("可下载"), systemImage: "arrow.down.circle").foregroundStyle(.orange)
        case .unsupported: Label(V2L("当前语言对不受支持"), systemImage: "xmark.circle").foregroundStyle(.red)
        case .preparing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text(V2L("正在下载…"))
            }
        case .failed(let message):
            Label(V2L(message), systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }
}

/// `TranslationSession.prepareTranslation` is the only system-approved download path.
/// The hidden host exists only while a request is active, so no session is retained.
struct TranslationLanguagePackHost: View {
    let request: TranslationLanguagePackRequest
    let finished: @MainActor (TranslationLanguagePackDownloadOutcome) -> Void

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .translationTask(.init(source: Locale.Language(identifier: request.source),
                                   target: Locale.Language(identifier: request.target)),
                             action: Self.action(finished: finished))
    }

    private nonisolated static func action(finished: @escaping @MainActor (TranslationLanguagePackDownloadOutcome) -> Void) -> (TranslationSession) async -> Void {
        { session in
            do {
                try Task.checkCancellation()
                if #available(macOS 26.0, *), !session.canRequestDownloads {
                    languagePackLogger.error("系统不允许请求语言下载 (canRequestDownloads=false), source=\(session.sourceLanguage?.maximalIdentifier ?? "nil", privacy: .public), target=\(session.targetLanguage?.maximalIdentifier ?? "nil", privacy: .public)")
                    await finished(.failure(.notInstalled))
                    return
                }
                try await session.prepareTranslation()
                try Task.checkCancellation()
                await finished(.success)
            } catch {
                guard !Task.isCancelled else { return }
                languagePackLogger.error("语言包下载失败: \(String(describing: error), privacy: .public)")
                await finished(.failure(.classify(error)))
            }
        }
    }
}
