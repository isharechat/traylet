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

    var isDownloading: Bool {
        request != nil || state == .preparing
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
        case .success, .failure(.cancelled):
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
        case .cancelled:
            return "已取消。"
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

struct TranslationLanguagePackStatusPresentation: Equatable {
    let symbol: String?
    let isSpinner: Bool
    let tint: Color
    let label: String
    let helpText: String
    let inlineNotice: String?

    init(state: TranslationLanguagePackState) {
        switch state {
        case .unknown:
            symbol = "questionmark.circle"
            isSpinner = false
            tint = .secondary
            label = "检查状态"
            helpText = "尚未检查，点击检查当前语言对状态"
            inlineNotice = nil
        case .checking:
            symbol = nil
            isSpinner = true
            tint = .secondary
            label = "正在检查…"
            helpText = "正在检查…"
            inlineNotice = nil
        case .installed:
            symbol = "checkmark.circle.fill"
            isSpinner = false
            tint = .green
            label = "检查状态"
            helpText = "已安装"
            inlineNotice = nil
        case .downloadable:
            symbol = "arrow.down.circle.fill"
            isSpinner = false
            tint = .orange
            label = "检查状态"
            helpText = "可下载"
            inlineNotice = nil
        case .unsupported:
            symbol = "xmark.circle.fill"
            isSpinner = false
            tint = .red
            label = "检查状态"
            helpText = "当前语言对不受支持"
            inlineNotice = "当前语言对不受支持"
        case .preparing:
            symbol = nil
            isSpinner = true
            tint = .secondary
            label = "检查状态"
            helpText = "正在下载…"
            inlineNotice = nil
        case .failed(let message):
            symbol = "exclamationmark.triangle.fill"
            isSpinner = false
            tint = .red
            label = "检查状态"
            helpText = message
            inlineNotice = message
        }
    }
}

@MainActor
struct TranslationLanguagePackSettings: View {
    @ObservedObject var controller: TranslationLanguagePackController

    var body: some View {
        let presentation = TranslationLanguagePackStatusPresentation(state: controller.state)
        Section(L("系统语言包")) {
            Picker(L("原文语言"), selection: $controller.source) {
                ForEach(languages, id: \.0) { Text(L($0.1)).tag($0.0) }
            }
            Picker(L("译文语言"), selection: $controller.target) {
                ForEach(languages, id: \.0) { Text(L($0.1)).tag($0.0) }
            }
            LabeledContent(L("状态")) {
                HStack(spacing: 8) {
                    checkStatusButton(presentation)
                    downloadButton
                }
            }
            if let notice = presentation.inlineNotice {
                Label(L(notice), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var languages: [(String, String)] {
        TranslationWorkspaceView.languages.filter { $0.0 != "auto" }
    }

    private func checkStatusButton(_ presentation: TranslationLanguagePackStatusPresentation) -> some View {
        Button { controller.check() } label: {
            HStack(spacing: 5) {
                if presentation.isSpinner {
                    ProgressView().controlSize(.mini)
                } else if let symbol = presentation.symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(presentation.tint)
                }
                Text(L(presentation.label))
            }
        }
        .controlSize(.small)
        .disabled(controller.state == .checking || controller.state == .preparing)
        .help(L(presentation.helpText))
        .accessibilityValue(L(presentation.helpText))
    }

    private var downloadButton: some View {
        Button { controller.download() } label: {
            if controller.state == .preparing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(L("正在下载…"))
                }
            } else {
                Text(L("下载语言包"))
            }
        }
        .controlSize(.small)
        .disabled(!controller.canDownload)
        .help(L("语言包由 macOS 按系统批准流程下载并安装到本机；不会上传原文、截图或剪贴板。"))
    }
}

/// `TranslationSession.prepareTranslation` is the only system-approved download path.
/// The hidden host exists only while a request is active, so no session is retained.
struct TranslationLanguagePackHost: View {
    let request: TranslationLanguagePackRequest
    let finished: @MainActor (TranslationLanguagePackDownloadOutcome) -> Void
    @State private var configuration: TranslationSession.Configuration

    init(request: TranslationLanguagePackRequest, finished: @escaping @MainActor (TranslationLanguagePackDownloadOutcome) -> Void) {
        self.request = request
        self.finished = finished
        _configuration = State(initialValue: .init(source: Locale.Language(identifier: request.source), target: Locale.Language(identifier: request.target)))
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .translationTask(configuration, action: Self.action(finished: finished))
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
