import AppKit
import SwiftUI
import TrayletCore

/// Explicit command-line evidence only. Never constructed by the production coordinator.
@MainActor enum V2NativeEvidence {
    struct ImageRecord: Codable {
        let name: String
        let width: Int
        let height: Int
        let byteCount: Int
        let windowWasVisible: Bool
    }
    struct Report: Encodable {
        let version = 2
        let passed = true
        let scope = "syntheticOffscreen"
        let syntheticOnly = true
        let externalRequests = 0
        let generalClipboardReads = 0
        let systemTranslationCalls = 0
        let visionCalls = 0
        let speechCalls = 0
        let registeredSystemShortcuts = 0
        let windowsShown = 0
        let images: [ImageRecord]
        let limitations: [String]
    }

    static func write(to directory: URL) async throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-evidence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = EvidenceClipboardSource()
        let output = EvidenceOutput()
        let clipboard = ClipboardFeature(directory: temporary, source: source, writer: output, clock: { Date(timeIntervalSince1970: 1_800_000_000) })
        do {
            var records: [ImageRecord] = []
            for scheme in [ColorScheme.light, .dark] {
                let brand = VStack(spacing: 24) {
                    HStack(spacing: 24) { ForEach([16, 32, 64, 128], id: \.self) { V2BrandIcon(size: CGFloat($0)) } }
                    HStack(spacing: 24) { ForEach([18, 36], id: \.self) { Image(nsImage: V2Brand.mark(size: CGFloat($0))).foregroundStyle(.primary) } }
                }.frame(width: 420, height: 240).background(Color(nsColor: .windowBackgroundColor))
                records.append(try await render(brand, size: CGSize(width: 420, height: 240), name: "brand-sizes-\(label(scheme))", in: directory, scheme: scheme))
                records.append(try await render(V2WelcomeView(english: false, openPermissions: {}, complete: {}).background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 520, height: 360), name: "welcome-\(label(scheme))", in: directory, scheme: scheme))
            }
            let fixture = try syntheticImage()
            for translationMode in [false, true] {
                let session = EditingSession(image: fixture, canvas: CGSize(width: 900, height: 620), fullScreen: false, writer: output)
                session.document.select(from: CGPoint(x: 70, y: 65), to: CGPoint(x: 830, y: 495))
                if !translationMode {
                    session.document.append(.init(tool: .rectangle, points: [.init(x: 36, y: 35), .init(x: 330, y: 150)], style: .init(color: .systemRed, width: 3)))
                    session.document.append(.init(tool: .text, points: [.init(x: 50, y: 200)], style: .init(color: .labelColor, fontSize: 26), text: "合成标注 · Capture an idea"))
                    session.document.append(.init(tool: .blur, points: [.init(x: 430, y: 330), .init(x: 650, y: 330)], style: .init(brushSize: 64)))
                    session.tool = .blur
                }
                for scheme in [ColorScheme.light, .dark] {
                    let name = translationMode ? "editor-translation-mode" : "editor-selection-rectangle-text-blur"
                    records.append(try await render(EditingCanvasView(session: session, selectingForTranslation: translationMode), size: CGSize(width: 900, height: 620), name: name + "-" + label(scheme), in: directory, scheme: scheme))
                }
                if !translationMode {
                    let exported = try session.composite()
                    let name = "editor-export-2x.png"
                    try exported.pngData.write(to: directory.appendingPathComponent(name), options: .atomic)
                    guard exported.width == 1520, exported.height == 860 else { throw EvidenceFailure.invalidDimensions(name) }
                    records.append(.init(name: name, width: exported.width, height: exported.height, byteCount: exported.pngData.count, windowWasVisible: false))
                }
            }

            let redaction = EditingSession(image: fixture, canvas: CGSize(width: 900, height: 620), fullScreen: false, writer: output)
            redaction.document.select(from: CGPoint(x: 70, y: 65), to: CGPoint(x: 830, y: 495))
            redaction.document.append(.init(tool: .redaction, points: [.init(x: 20, y: 40), .init(x: 385, y: 100)]))
            redaction.tool = .redaction
            for scheme in [ColorScheme.light, .dark] {
                records.append(try await render(EditingCanvasView(session: redaction, selectingForTranslation: false), size: CGSize(width: 900, height: 620), name: "editor-redaction-\(label(scheme))", in: directory, scheme: scheme))
            }

            let configuration = TranslationConfiguration(client: EvidenceAI())
            let controller = TranslationController(configuration: configuration, writer: output, availability: EvidenceResources(), recognizer: EvidenceRecognition(), speech: EvidenceSpeech())
            controller.flow.source = "en"; controller.flow.target = "zh-Hans"
            controller.flow.input = "Synthetic preview\n\nA small tool can make everyday work feel simpler. Capture an idea, translate a sentence, and keep moving."
            guard let completed = controller.flow.begin(engine: .system) else { throw EvidenceFailure.fixtureState }
            controller.flow.complete(completed, text: "合成演示译文（非系统翻译结果）\n\n一个小工具，可以让日常工作更轻松。捕捉一个想法，翻译一句话，然后继续前行。")
            for scheme in [ColorScheme.light, .dark] {
                records.append(try await render(TranslationWorkspaceView(controller: controller, flow: controller.flow, configuration: configuration), size: CGSize(width: 600, height: 630), name: "translation-\(label(scheme))", in: directory, scheme: scheme))
            }
            controller.flow.input = String(repeating: "Synthetic long paragraph: local capture, editable text, explicit actions. 中文长文仅用于原生排版检查。\n\n", count: 30)
            for state in ["long", "processing", "error", "resource"] {
                if state == "error" {
                    await controller.submit() // The fake resource checker deliberately fails before creating any live host.
                    guard controller.systemWork == nil, controller.canRetrySubmission else { throw EvidenceFailure.fixtureState }
                } else if state != "long" {
                    guard let work = controller.flow.begin(engine: .system) else { throw EvidenceFailure.fixtureState }
                    if state == "resource" { controller.flow.requireResource(work) }
                }
                records.append(try await render(TranslationWorkspaceView(controller: controller, flow: controller.flow, configuration: configuration), size: CGSize(width: 440, height: 480), name: "translation-narrow-\(state)", in: directory))
            }
            configuration.engine = .ai; configuration.endpoint = "https://example.invalid/v1"
            configuration.model = "synthetic-translate-small"; configuration.credential = "synthetic-memory-only"
            configuration.request(.models)
            guard let modelRequest = configuration.preview else { throw EvidenceFailure.fixtureState }
            await configuration.confirm(modelRequest) // In-process fake; no URLSession exists in this dependency.
            guard configuration.models.count == 3 else { throw EvidenceFailure.fixtureState }
            for scheme in [ColorScheme.light, .dark] {
                records.append(try await render(NSHostingView(rootView: TranslationConfigurationView(configuration: configuration, expanded: [.ai]).padding(24).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)), size: CGSize(width: 660, height: 1000), name: "ai-configuration-models-\(label(scheme))", in: directory, scheme: scheme))
            }
            let request = try configuration.makeRequest(.translate, content: "Synthetic text preview. 此正文不会发出。", source: "en", target: "zh-Hans")
            records.append(try await render(TranslationSendPreview(request: request, cancel: {}, send: {}), size: CGSize(width: 540, height: 420), name: "translation-ai-send-preview", in: directory))
            controller.cancel()

            for scheme in [ColorScheme.light, .dark] {
                records.append(try await render(ClipboardFeatureView(feature: clipboard), size: CGSize(width: 360, height: 460), name: "clipboard-disabled-\(label(scheme))", in: directory, scheme: scheme))
            }
            guard !clipboard.controller.enabled, source.reads == 0 else { throw EvidenceFailure.fixtureState }
            await clipboard.start(poll: false)
            guard clipboard.controller.enabled, clipboard.controller.entries.isEmpty else { throw EvidenceFailure.fixtureState }
            records.append(try await render(ClipboardFeatureView(feature: clipboard), size: CGSize(width: 740, height: 510), name: "clipboard-empty", in: directory))
            source.value = .init(generation: 1, items: [.text("合成文字 · 项目备忘\n周五前校对快捷键与翻译设置。全部内容由验收生成。")], application: "com.example.SyntheticNotes")
            await clipboard.controller.refresh()
            guard let favorite = clipboard.controller.entries.first?.id else { throw EvidenceFailure.fixtureState }
            await clipboard.controller.toggleFavorite(favorite)
            var mixed = ClipboardContent.text("合成图片 · 本机验收构造的图片与文字")
            mixed.representations["public.png"] = fixture.pngData
            source.value = .init(generation: 2, items: [mixed], application: "com.example.SyntheticCanvas")
            await clipboard.controller.refresh()
            guard clipboard.controller.entries.count == 2 else { throw EvidenceFailure.fixtureState }
            clipboard.controller.selectedID = clipboard.controller.entries.first?.id
            for scheme in [ColorScheme.light, .dark] {
                records.append(try await render(ClipboardFeatureView(feature: clipboard), size: CGSize(width: 740, height: 510), name: "clipboard-text-image-\(label(scheme))", in: directory, scheme: scheme))
            }
            clipboard.controller.query = "项目备忘"; clipboard.controller.favoritesOnly = true; clipboard.controller.selectedID = favorite
            records.append(try await render(ClipboardFeatureView(feature: clipboard), size: CGSize(width: 740, height: 510), name: "clipboard-favorite-search", in: directory))
            await clipboard.shutdownAndWait()

            let settingsClipboard = ClipboardFeature(directory: temporary.appendingPathComponent("settings"), source: EvidenceClipboardSource(), writer: output)
            let preferences = V2PreferencesStore()
            let shortcuts = V2ShortcutManager(preferences: preferences, driver: EvidenceShortcutDriver())
            let actions = V2SettingsActions(preferences: preferences, login: EvidenceLogin())
            let settingsTranslation = TranslationConfiguration(client: EvidenceAI())
            for scheme in [ColorScheme.light, .dark] {
                for (widthName, size) in [("wide", CGSize(width: 780, height: 650)), ("narrow", CGSize(width: 560, height: 420))] {
                    let navigation = V2SettingsNavigation()
                    let view = V2SettingsWorkspaceView(preferences: preferences, shortcuts: shortcuts, translation: settingsTranslation, clipboard: settingsClipboard, navigation: navigation, actions: actions)
                        .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme).transaction { $0.disablesAnimations = true }.frame(width: size.width, height: size.height)
                    let host = NSHostingView(rootView: view)
                    let window = makeWindow(host, size: size, scheme: scheme)
                    do {
                        try await settle(host)
                        for section in V2SettingsSection.allCases {
                            navigation.navigate(to: section)
                            try await settle(host, milliseconds: 350)
                            records.append(try cache(host, window: window, name: "settings-\(label(scheme))-\(widthName)-\(section.rawValue)", in: directory))
                        }
                        window.contentView = nil; window.close()
                    } catch { window.contentView = nil; window.close(); throw error }
                }
            }
            await settingsClipboard.shutdownAndWait()
            guard !settingsClipboard.controller.enabled, output.calls == 0 else { throw EvidenceFailure.fixtureState }
            let report = Report(images: records, limitations: ["passed 仅表示本次合成离屏生成流程通过，不代表产品放行。", "仅合成数据和真实 V2 原生视图的离屏渲染；译文不是系统翻译结果。", "不验证真实屏幕录制、Vision、语言包、语音、general 剪贴板或外部 AI 服务。", "首启使用纯视图和空动作；未创建生产 coordinator，未打开系统设置。"])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: directory.appendingPathComponent("evidence-report.json"), options: .atomic)
        } catch { await clipboard.shutdownAndWait(); throw error }
    }

    private static func label(_ scheme: ColorScheme) -> String { scheme == .dark ? "dark" : "light" }
    private static func render<V: View>(_ view: V, size: CGSize, name: String, in directory: URL, scheme: ColorScheme = .light) async throws -> ImageRecord {
        // Offscreen windows have no WindowServer backdrop. Give SwiftUI content its semantic window base,
        // otherwise transparent regions (including black text on a clear light canvas) are not inspectable.
        try await render(NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme).transaction { $0.disablesAnimations = true }), size: size, name: name, in: directory, scheme: scheme)
    }
    private static func render(_ view: NSView, size: CGSize, name: String, in directory: URL, scheme: ColorScheme = .light) async throws -> ImageRecord {
        let window = makeWindow(view, size: size, scheme: scheme)
        defer { window.contentView = nil; window.close() }
        try await settle(view)
        return try cache(view, window: window, name: name, in: directory)
    }
    private static func makeWindow(_ view: NSView, size: CGSize, scheme: ColorScheme) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = view; view.frame = NSRect(origin: .zero, size: size)
        return window
    }
    private static func settle(_ view: NSView, milliseconds: Int = 120) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(milliseconds))
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
    }
    private static func cache(_ view: NSView, window: NSWindow, name: String, in directory: URL) throws -> ImageRecord {
        guard !window.isVisible else { throw EvidenceFailure.visibleWindow(name) }
        let width = Int(view.bounds.width * 2), height = Int(view.bounds.height * 2)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw EvidenceFailure.bitmap(name) }
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard !window.isVisible, let data = bitmap.representation(using: .png, properties: [:]), data.count > 1000,
              let decoded = NSBitmapImageRep(data: data), decoded.pixelsWide == width, decoded.pixelsHigh == height else { throw EvidenceFailure.invalidDimensions(name) }
        let filename = name + ".png"
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        return .init(name: filename, width: width, height: height, byteCount: data.count, windowWasVisible: window.isVisible)
    }

    /// Crisp 2x document made from local drawing commands, independent of the display.
    private static func syntheticImage() throws -> RasterImage {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 1240, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw EvidenceFailure.bitmap("fixture") }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        NSColor(calibratedRed: 0.92, green: 0.95, blue: 0.98, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1800, height: 1240).fill()
        NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: 80, y: 140, width: 1640, height: 1000), xRadius: 24, yRadius: 24).fill()
        ("Traylet · Synthetic workspace" as NSString).draw(at: CGPoint(x: 180, y: 940), withAttributes: [.font: NSFont.systemFont(ofSize: 52, weight: .semibold), .foregroundColor: NSColor.black])
        ("Capture a clear idea.\nLocal pixels · Native controls · Explicit actions\n合成文档用于框选、标注与高斯模糊验收。" as NSString).draw(in: NSRect(x: 180, y: 530, width: 1400, height: 300), withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.darkGray])
        for i in 0..<30 { (i.isMultiple(of: 2) ? NSColor.systemTeal : NSColor.systemIndigo).setFill(); NSRect(x: CGFloat(920 + i * 18), y: 400, width: 9, height: 100).fill() }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw EvidenceFailure.bitmap("fixture") }
        return try RasterImage(pngData: data)
    }
}

private enum EvidenceFailure: Error { case fixtureState, visibleWindow(String), bitmap(String), invalidDimensions(String) }
private struct EvidenceAI: TranslationAIClient {
    func perform(_ request: TranslationAIRequest) async throws -> TranslationAIResult {
        guard request.action == .models else { throw EvidenceFailure.fixtureState }
        return .models(["synthetic-reasoning", "synthetic-translate-small", "synthetic-vision"])
    }
}
private struct EvidenceResources: TranslationResourceChecking {
    func status(text: String, source: String, target: String) async throws -> TranslationResourceState { throw EvidenceFailure.fixtureState }
}
private struct EvidenceRecognition: TranslationRecognizing {
    func recognize(_ image: RasterImage) async throws -> String { throw EvidenceFailure.fixtureState }
}
@MainActor private final class EvidenceSpeech: TranslationSpeaking {
    var onFinish: (@MainActor () -> Void)?
    func speak(_ text: String, language: String) throws { throw EvidenceFailure.fixtureState }
    func stop() {}
}
@MainActor private final class EvidenceClipboardSource: ClipboardSource {
    private(set) var reads = 0
    var value: V2ClipboardSnapshot?
    var generation: Int { value?.generation ?? 0 }
    func read(expectedGeneration: Int, excluding: Set<String>) -> V2ClipboardSnapshot? {
        reads += 1
        return value?.generation == expectedGeneration ? value : nil
    }
}
@MainActor private final class EvidenceOutput: TextOutputWriting, ImageOutputWriting, ClipboardWriting {
    private(set) var calls = 0
    func copyText(_ text: String) -> CopyOutcome { calls += 1; return .failed }
    func copyImage(_ image: RasterImage) -> CopyOutcome { calls += 1; return .failed }
    func write(_ items: [ClipboardContent], marker: String) -> ClipboardWriteResult { calls += 1; return .failed }
}
@MainActor private final class EvidenceShortcutDriver: V2ShortcutRegistering {
    var onInvoke: ((V2Action) -> Void)?
    func prepare(_ bindings: [V2ShortcutAssignment]) throws -> any V2ShortcutUpdate { throw EvidenceFailure.fixtureState }
    func stop() {}
}
@MainActor private final class EvidenceLogin: V2LoginItemManaging {
    var enabled = false
    var requiresApproval = false
    func setEnabled(_ value: Bool) throws { throw EvidenceFailure.fixtureState }
}
