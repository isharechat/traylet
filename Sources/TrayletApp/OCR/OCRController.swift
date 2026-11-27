import AppKit
import SwiftUI
import Combine
import ImageIO
import TrayletCore

@MainActor final class OCRController: NSObject, ObservableObject, NSWindowDelegate {
    let configuration: OCRConfiguration
    @Published private(set) var image: RasterImage?
    @Published private(set) var previewImage: NSImage?
    @Published var text = ""
    @Published private(set) var rawText = ""
    @Published var selectedEngine: OCREngineChoice
    @Published var selectedPreset: OCRAIPreset
    @Published private(set) var phase: OCRPhase = .idle
    @Published private(set) var notice = ""
    @Published var showsPreview = true
    @Published private(set) var speaking = false
    @Published var zoomScale: CGFloat = 1.0

    var onTranslate: ((String, RasterImage?) -> Void)?
    var onRecapture: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    var windowTitle: String { L("OCR 识别") }
    var isPresented: Bool { panel?.isVisible == true }
    var recognitionTaskHandle: Task<Void, Never>? { recognitionTask }

    private let visionRecognizer: any TranslationRecognizing
    private let aiRecognizer: any OCRAIRecognizing
    private let writer: any TextOutputWriting
    private let speech: any TranslationSpeaking
    private let presentWindow: (NSPanel) -> Void
    private var panel: NSPanel?
    private var backing: GlassWindowBacking?
    private var dismissal: NSObjectProtocol?
    private var recognitionTask: Task<Void, Never>?
    private var operationID: UUID?
    private var observers: Set<AnyCancellable> = []

    init(
        configuration: OCRConfiguration = OCRConfiguration(),
        visionRecognizer: any TranslationRecognizing = TranslationVisionOCR(),
        aiRecognizer: any OCRAIRecognizing = OCROpenAIClient(),
        writer: any TextOutputWriting = SystemClipboardWriter(),
        speech: any TranslationSpeaking = TranslationLocalSpeech(),
        presentWindow: @escaping (NSPanel) -> Void = { panel in
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.configuration = configuration
        self.selectedEngine = configuration.defaultEngine
        self.selectedPreset = configuration.preset
        self.visionRecognizer = visionRecognizer
        self.aiRecognizer = aiRecognizer
        self.writer = writer
        self.speech = speech
        self.presentWindow = presentWindow
        super.init()

        self.speech.onFinish = { [weak self] in self?.speaking = false }
        Localization.shared.$languageCode.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.panel?.title = self.windowTitle
            }
        }.store(in: &observers)
    }

    func present(
        image: RasterImage? = nil,
        decoded: CGImage? = nil,
        autoRecognize: Bool = true,
        elevatedAboveEditor: Bool = false
    ) {
        ensurePanel()
        if let panel {
            if elevatedAboveEditor {
                panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            } else {
                panel.level = .normal
                panel.collectionBehavior = []
            }
        }
        notice = ""
        if let image {
            setImage(image, decoded: decoded)
            selectedEngine = configuration.defaultEngine
            selectedPreset = configuration.preset
            if autoRecognize {
                recognize()
            } else {
                phase = text.isEmpty ? .idle : .ready
            }
        }
        if let panel { presentWindow(panel) }
    }

    func setImage(_ image: RasterImage, decoded: CGImage? = nil) {
        self.image = image
        if let decoded, decoded.width == image.width, decoded.height == image.height {
            self.previewImage = NSImage(cgImage: decoded, size: NSSize(width: image.width, height: image.height))
        } else {
            self.previewImage = NSImage(data: image.pngData)
        }
        self.zoomScale = 1.0
    }

    @discardableResult
    func recognize(engine: OCREngineChoice? = nil) -> Task<Void, Never>? {
        if let engine { selectedEngine = engine }
        guard let image else {
            phase = .failed("请先截图或导入图片。")
            return nil
        }
        cancelRecognition()
        notice = ""
        let id = UUID()
        operationID = id
        phase = .recognizing

        let usedEngine = selectedEngine
        let usedPreset = selectedPreset
        let aiSettings = configuration.effectiveSettings
        let prompt = configuration.effectivePrompt(for: usedPreset)
        let shouldMerge = configuration.mergeLineBreaks
        let shouldAutoCopy = configuration.autoCopy

        let task = Task { [weak self, visionRecognizer, aiRecognizer] in
            guard !Task.isCancelled else { return }
            do {
                let result: String
                switch usedEngine {
                case .vision:
                    result = try await visionRecognizer.recognize(image)
                case .ai:
                    let request = OCRAIRequest(settings: aiSettings, imageData: image.pngData, prompt: prompt)
                    result = try await aiRecognizer.recognize(request)
                }
                guard !Task.isCancelled, let self, self.operationID == id else { return }
                self.rawText = result
                self.text = shouldMerge ? OCRTextPostProcessor.mergeLineBreaks(result) : result
                self.phase = .ready
                self.operationID = nil
                self.recognitionTask = nil
                if shouldAutoCopy, !self.text.isEmpty {
                    self.copyText()
                }
            } catch {
                guard !Task.isCancelled, let self, self.operationID == id else { return }
                let message = Self.errorMessage(for: error)
                self.phase = .failed(message)
                self.operationID = nil
                self.recognitionTask = nil
            }
        }
        recognitionTask = task
        return task
    }

    func selectEngine(_ engine: OCREngineChoice) {
        let changed = selectedEngine != engine
        selectedEngine = engine
        if image != nil && (changed || phase != .recognizing) {
            recognize(engine: engine)
        }
    }

    func selectPreset(_ preset: OCRAIPreset) {
        let changed = selectedPreset != preset
        selectedPreset = preset
        if image != nil && selectedEngine == .ai && changed {
            recognize(engine: .ai)
        }
    }

    func applyMergeLineBreaks() {
        guard !text.isEmpty else { return }
        text = OCRTextPostProcessor.mergeLineBreaks(text)
        notice = "已合并换行。"
    }

    func copyText() {
        guard !text.isEmpty else { return }
        switch writer.copyText(text) {
        case .copied: notice = "已复制。"
        case .changed: notice = "剪贴板在复制时发生变化，请重试。"
        case .failed: notice = "复制失败，请重试；系统剪贴板可能已经清空。"
        }
    }

    func clear() {
        cancelRecognition()
        text = ""
        rawText = ""
        notice = ""
        phase = .idle
        stopSpeaking()
    }

    func toggleSpeaking() {
        if speaking {
            stopSpeaking()
            return
        }
        guard !text.isEmpty else { return }
        do {
            try speech.speak(text, language: "auto")
            speaking = true
            notice = ""
        } catch {
            speaking = false
            notice = (error as? FeatureIssue)?.localizedDescription ?? "朗读无法开始，请检查本机语音资源。"
        }
    }

    func stopSpeaking() {
        speech.stop()
        speaking = false
    }

    func sendToTranslation() {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        onTranslate?(text, image)
    }

    func recapture() {
        onRecapture?()
    }

    func openSettings() {
        onOpenSettings?()
    }

    func importImage(from url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            phase = .failed("无法读取所选图片文件。")
            return
        }
        importImageData(data)
    }

    func importImageData(_ data: Data) {
        if let direct = try? RasterImage(pngData: data) {
            setImage(direct)
            recognize()
            return
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            phase = .failed("不支持的图片格式或文件已损坏。")
            return
        }
        let mutable = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutable, "public.png" as CFString, 1, nil) else {
            phase = .failed("无法转换图片格式。")
            return
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest),
              let raster = try? RasterImage(pngData: mutable as Data) else {
            phase = .failed("图片尺寸超出安全限制。")
            return
        }
        setImage(raster, decoded: cgImage)
        recognize()
    }

    func cancel() {
        cancelRecognition()
        stopSpeaking()
    }

    func close() {
        cancel()
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        close()
    }

    private func cancelRecognition() {
        operationID = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        if phase == .recognizing {
            phase = text.isEmpty ? .idle : .ready
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let created = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        created.title = windowTitle
        created.minSize = NSSize(width: 540, height: 420)
        created.isReleasedWhenClosed = false
        created.hidesOnDeactivate = false
        backing = GlassWindowBacking(
            window: created,
            content: NSHostingView(rootView: OCRWorkspaceView(controller: self))
        )
        created.delegate = self
        created.center()
        panel = created
        dismissal = FloatingWindow.hideOnResignKey(created) { [weak self] in
            self?.close()
        }
    }

    private static func errorMessage(for error: Error) -> String {
        if let issue = error as? FeatureIssue {
            return issue.localizedDescription
        }
        if let aiFailure = error as? TranslationAIFailure {
            return aiFailure.localizedDescription
        }
        return TranslationAIFailure.safeMessage(error)
    }
}
