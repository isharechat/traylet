import AppKit
import SwiftUI
import Combine
import TrayletCore

@MainActor final class TranslationController: NSObject, ObservableObject, NSWindowDelegate {
    let configuration: TranslationConfiguration
    let flow = TranslationFlow()
    var onOpenSettings: ((TranslationLanguagePackPair?) -> Void)?
    var windowTitle: String { V2L("翻译") }
    @Published private(set) var systemWork: TranslationWork?
    @Published private(set) var preparingResources = false
    @Published private(set) var preview: TranslationAIRequest?
    @Published private(set) var notice = ""
    /// The last selected-text read was blocked because macOS Accessibility trust is missing.
    @Published private(set) var accessibilityNotice = false
    /// True for the source box, false for the translation box, nil when nothing is being read aloud.
    @Published private(set) var speakingSource: Bool?
    /// The engine the Translate button and the icon row currently use; it starts as the default engine.
    @Published private(set) var selectedEngine: TranslationEngineChoice
    /// Engines whose first send of this window session was already confirmed; later sends to them go out directly.
    private var confirmedEngines: Set<TranslationEngineChoice> = []
    private var lastDefault: TranslationEngineChoice
    private let writer: any TextOutputWriting
    private let availability: any TranslationResourceChecking
    private let recognizer: any TranslationRecognizing
    private let speech: any TranslationSpeaking
    private let presentWindow: (NSPanel) -> Void
    private var panel: NSPanel?
    private var backing: V2GlassWindowBacking?
    private var dismissal: NSObjectProtocol?
    private var requestTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []
    private struct RetryContext {
        let work: TranslationWork
        let configurationRevision: UUID
    }
    @Published private var retryContext: RetryContext?
    init(configuration: TranslationConfiguration = TranslationConfiguration(), writer: any TextOutputWriting = V2SystemClipboardWriter(), availability: any TranslationResourceChecking = TranslationSystemResources(), recognizer: any TranslationRecognizing = TranslationVisionOCR(), speech: any TranslationSpeaking = TranslationLocalSpeech(),
         presentWindow: @escaping (NSPanel) -> Void = { panel in panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }) {
        self.configuration = configuration; selectedEngine = configuration.engine; lastDefault = configuration.engine; self.writer = writer; self.availability = availability; self.recognizer = recognizer; self.speech = speech
        self.presentWindow = presentWindow
        super.init()
        self.speech.onFinish = { [weak self] in self?.speakingSource = nil }
        configuration.$revision.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            cancel(); flow.markOutputStale(); confirmedEngines = []
            // Choosing another default in Settings makes it the window's engine too.
            if configuration.engine != lastDefault || !configuration.availableEngines.contains(selectedEngine) { selectedEngine = configuration.engine }
            lastDefault = configuration.engine
        }.store(in: &observers)
        configuration.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateMinimumSize() }
        }.store(in: &observers)
        flow.$input.removeDuplicates().dropFirst().sink { [weak self] _ in self?.invalidateWork() }.store(in: &observers)
        flow.$source.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.invalidateWork()
            Task { @MainActor [weak self] in self?.updateMinimumSize() }
        }.store(in: &observers)
        flow.$target.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.invalidateWork()
            Task { @MainActor [weak self] in self?.updateMinimumSize() }
        }.store(in: &observers)
        V2Localization.shared.$languageCode.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.panel?.title = self.windowTitle
                self.updateMinimumSize()
            }
        }.store(in: &observers)
    }
    /// Every visible engine icon must fit beside the language and Translate controls at the smallest window width.
    private func updateMinimumSize() {
        guard let panel else { return }
        // Match the native callout labels, capsule padding, chevrons and fixed controls.
        // A constant Chinese width truncates Translate after switching to English.
        let font = NSFont.preferredFont(forTextStyle: .callout)
        func textWidth(_ value: String) -> CGFloat { (V2L(value) as NSString).size(withAttributes: [.font: font]).width }
        func languageWidth(_ code: String) -> CGFloat {
            textWidth(TranslationWorkspaceView.languages.first { $0.0 == code }?.1 ?? code) + 20 + 4 + 9
        }
        let count = max(1, configuration.visibleEngines.count)
        let engines = CGFloat(count) * V2Design.iconButton + CGFloat(count - 1) * 6
        let labels = languageWidth(flow.source) + languageWidth(flow.target) + textWidth("翻译") + 28
        let controls = V2Design.iconButton * 2 + engines + 36 + 4
        let width = ceil(max(CGFloat(434 + 34 * count), labels + controls + V2Design.Space.m * 2 + 8))
        panel.minSize = NSSize(width: width, height: 440)
        if panel.contentLayoutRect.width < width { panel.setContentSize(NSSize(width: width, height: panel.contentLayoutRect.height)) }
    }
    /// Picks another engine from the icon row; existing source text is translated right away.
    func select(_ engine: TranslationEngineChoice) {
        guard flow.phase != .recognizing, configuration.availableEngines.contains(engine) else { return }
        let changed = selectedEngine != engine
        if changed {
            // Invalidate the old host and output before scheduling the replacement task.
            cancel(); flow.markOutputStale()
        }
        selectedEngine = engine
        // Picking an engine is already an explicit choice; send without another confirmation sheet.
        if !flow.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, changed || flow.phase != .translating {
            startSubmission(skipPreview: changed)
        }
    }
    func present(text: String = "", image: RasterImage? = nil, decoded: CGImage? = nil) {
        cancel(); notice = ""; accessibilityNotice = false; selectedEngine = configuration.engine
        if image == nil, !text.isEmpty { flow.input = text; flow.clearOutput() }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 630), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = windowTitle; panel.isReleasedWhenClosed = false
            backing = V2GlassWindowBacking(window: panel, content: NSHostingView(rootView: TranslationWorkspaceView(controller: self, flow: flow, configuration: configuration)))
            panel.delegate = self; panel.center(); self.panel = panel; updateMinimumSize()
            dismissal = V2FloatingWindow.hideOnResignKey(panel) { [weak self] in self?.close() }
        }
        updateMinimumSize()
        if let panel { presentWindow(panel) }
        if let image { beginImageInput(image, decoded: decoded) }
    }
    func showAccessibilityNotice() { accessibilityNotice = true }
    func openAccessibilitySettings() { V2AccessibilitySelectedText.openSettings() }
    @discardableResult func beginImageInput(_ image: RasterImage, decoded: CGImage? = nil) -> Task<Void, Never> {
        cancel(); notice = ""
        let id = flow.beginRecognition()
        let task = Task { [weak self, recognizer] in
            guard !Task.isCancelled else { return }
            do {
                let result: String
                if let decoded {
                    guard decoded.width == image.width, decoded.height == image.height else { throw FeatureIssue.invalidInput("无法读取截图。") }
                    result = try await recognizer.recognize(image, decoded: decoded)
                } else { result = try await recognizer.recognize(image) }
                guard !Task.isCancelled else { return }
                self?.flow.finishRecognition(id, text: result)
            }
            catch {
                if !Task.isCancelled {
                    self?.flow.failRecognition(id, tooLong: (error as? FeatureIssue) == .invalidInput("识别文字过长。"))
                }
            }
        }
        recognitionTask = task
        return task
    }
    func close() { cancel(); confirmedEngines = []; panel?.orderOut(nil) }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        close()
    }
    func cancel() {
        let wasRecognizing = flow.phase == .recognizing
        invalidateWork(); flow.cancel()
        if wasRecognizing { notice = "已取消截图文字识别；已有原文和译文已保留。" }
    }
    private func invalidateWork() {
        if retryContext != nil { retryContext = nil }
        requestTask?.cancel(); requestTask = nil; recognitionTask?.cancel(); recognitionTask = nil
        // Runs per keystroke; unchanged values are not reassigned so the window is not redrawn for nothing.
        if systemWork != nil { systemWork = nil }
        if preview != nil { preview = nil }
        if preparingResources { preparingResources = false }
        speech.stop()
        if speakingSource != nil { speakingSource = nil }
    }
    /// The submission started by the Translate button or an engine icon, so callers and tests can wait for it.
    var submissionTask: Task<Void, Never>? { requestTask }
    /// The image action is independently awaitable; preparing history pixels does not finish OCR.
    var imageInputTask: Task<Void, Never>? { recognitionTask }
    /// A failed submission can be retried only while its text, language pair, engine and configuration still match.
    /// OCR failures and invalid input are not replayed as unrelated translation requests.
    var canRetrySubmission: Bool {
        guard let retryContext, case .failed = flow.phase else { return false }
        let work = retryContext.work
        return retryContext.configurationRevision == configuration.revision && work.text == flow.input
            && work.source == flow.source && work.target == flow.target && work.engine == selectedEngine
            && configuration.availableEngines.contains(work.engine)
    }
    func retrySubmission() {
        guard canRetrySubmission else { return }
        // Consume synchronously; a second click cannot enqueue another retry or replay a stale preview.
        cancel()
        startSubmission()
    }
    private func failSubmission(_ work: TranslationWork, message: String) {
        guard flow.isCurrent(work) else { return }
        retryContext = RetryContext(work: work, configurationRevision: configuration.revision)
        flow.fail(work, message: message)
    }
    func startSubmission(skipPreview: Bool = false) {
        guard flow.phase != .recognizing else { return }
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.submit(skipPreview: skipPreview)
        }
    }
    func submit(skipPreview: Bool = false) async {
        guard !Task.isCancelled, flow.phase != .recognizing else { return }
        if retryContext != nil { retryContext = nil }
        systemWork = nil; preview = nil; preparingResources = false; notice = ""
        guard let work = flow.begin(engine: selectedEngine) else { return }
        if work.engine != .system {
            do {
                guard let action = work.engine.translateAction else { return }
                let request = try configuration.makeRequest(action, content: work.text, source: work.source, target: work.target)
                preview = request
                // The Translate button confirms the first send to an engine; engine-icon switches send directly.
                if skipPreview || confirmedEngines.contains(work.engine) { await sendConfirmed(request) }
            } catch {
                // A local endpoint/model/credential validation error requires configuration changes,
                // rather than replaying the unchanged request from the error row.
                flow.fail(work, message: TranslationAIFailure.safeMessage(error))
            }
            return
        }
        do {
            let resource = try await availability.status(text: work.text, source: work.resolvedSource ?? "auto", target: work.target)
            guard flow.isCurrent(work), !Task.isCancelled else { return }
            switch resource {
            case .installed: systemWork = work
            case .downloadable: flow.requireResource(work)
            case .unsupported: flow.fail(work, message: "系统暂不支持此语言对；可更换语言或明确选择 AI。")
            }
        } catch TranslationResourceCheckError.unableToIdentifyLanguage {
            failSubmission(work, message: "无法识别原文语言，请选择明确的原文语言后重试。")
        } catch { failSubmission(work, message: "无法检查系统语言资源，请稍后重试。") }
    }
    func prepareLanguages() {
        guard let work = flow.active, flow.phase == .resourceRequired else { return }
        guard work.resolvedSource != nil else { notice = "无法识别原文语言，请选择明确的原文语言后重新提交。"; return }
        preparingResources = true; flow.startConfirmed(work); systemWork = work
    }
    /// Opens Translation settings, where language packs can be checked and downloaded ahead of time.
    func openLanguageSettings() {
        let source = flow.source == "auto" ? flow.detectedLanguage : flow.source
        let pair = source.map { TranslationLanguagePackPair(source: $0, target: flow.target) }
        onOpenSettings?(pair)
    }
    func finishSystem(_ work: TranslationWork, text: String) {
        guard flow.isCurrent(work), systemWork == work else { return }
        systemWork = nil; preparingResources = false; flow.complete(work, text: text)
    }
    func failSystem(_ work: TranslationWork) {
        guard flow.isCurrent(work), systemWork == work else { return }
        systemWork = nil; preparingResources = false; failSubmission(work, message: "系统翻译未完成。请检查语言资源后重试，或更换语言。")
    }
    func sendConfirmed(_ request: TranslationAIRequest) async {
        guard !Task.isCancelled, preview == request, let work = flow.active, work.engine != .system,
              request.settings == configuration.settings(for: work.engine), work.text == request.content else { return }
        preview = nil; confirmedEngines.insert(work.engine); flow.startConfirmed(work)
        do {
            let result = try await configuration.client.perform(request)
            guard !Task.isCancelled, request.settings == configuration.settings(for: work.engine), flow.isCurrent(work) else { return }
            guard case .text(let text) = result else { throw TranslationAIFailure.malformed }
            flow.complete(work, text: text)
        } catch { failSubmission(work, message: TranslationAIFailure.safeMessage(error)) }
    }
    func startConfirmed(_ request: TranslationAIRequest) {
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.sendConfirmed(request)
        }
    }
    func clearOutput() { cancel(); flow.clearOutput() }
    func copy(_ text: String) {
        switch writer.copyText(text) {
        case .copied: notice = "已复制。"
        case .changed: notice = "剪贴板在复制时发生变化，请重试。"
        case .failed: notice = "复制失败，请重试；系统剪贴板可能已经清空。"
        }
    }
    /// Starts reading a box aloud, or stops if that box is already being read.
    func toggleSpeaking(_ text: String, language: String, source: Bool) {
        if speakingSource == source { stopSpeaking(); return }
        do { try speech.speak(text, language: language); speakingSource = source; notice = "" }
        catch { speakingSource = nil; notice = (error as? FeatureIssue)?.localizedDescription ?? "朗读无法开始，请检查本机语音资源。" }
    }
    func stopSpeaking() { speech.stop(); speakingSource = nil }
}
