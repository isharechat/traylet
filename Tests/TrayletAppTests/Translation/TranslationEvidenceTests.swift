import AppKit
import SwiftUI
import Foundation
import Testing
@testable import TrayletApp

@Suite("Translation native evidence") @MainActor
struct TranslationEvidenceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAYLET_REWRITE_TRANSLATION_EVIDENCE_DIR"] != nil, "Offscreen evidence is an explicit synthetic-only action."))
    func writesSyntheticNativeViews() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TRAYLET_REWRITE_TRANSLATION_EVIDENCE_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let config = TranslationConfiguration(client: TranslationEvidenceAI())
        let controller = TranslationController(configuration: config, writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), speech: TranslationFakeSpeech())
        controller.flow.source = "en"; controller.flow.target = "zh-Hans"
        controller.flow.input = "Synthetic preview\n\nA small tool can make everyday work feel simpler. Capture an idea, translate a sentence, and keep moving."
        let work = try #require(controller.flow.begin(engine: .system))
        controller.flow.complete(work, text: "合成演示译文\n\n一个小工具，可以让日常工作更轻松。捕捉一个想法，翻译一句话，然后继续前行。")
        try render(TranslationWorkspaceView(controller: controller, flow: controller.flow, configuration: config), size: NSSize(width: 600, height: 630), to: directory.appendingPathComponent("translation-window-light.png"))
        try render(TranslationWorkspaceView(controller: controller, flow: controller.flow, configuration: config), size: NSSize(width: 600, height: 630), to: directory.appendingPathComponent("translation-window-dark.png"), scheme: .dark)
        await controller.submit() // Fake resources only; fail before any host view is rendered.
        controller.failSystem(try #require(controller.systemWork))
        #expect(controller.canRetrySubmission)
        try render(TranslationWorkspaceView(controller: controller, flow: controller.flow, configuration: config), size: NSSize(width: 440, height: 480), to: directory.appendingPathComponent("translation-window-narrow-error.png"))
        config.engine = .ai; config.endpoint = "https://example.invalid/v1"; config.model = "synthetic-translate-small"; config.credential = "synthetic-preview-key"
        config.request(.models)
        await config.confirm(try #require(config.preview))
        try render(VStack(alignment: .leading, spacing: 16) { Text("翻译设置 · 合成演示").font(.title2); TranslationConfigurationView(configuration: config); Spacer(minLength: 0) }.padding(24).background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 660, height: 610), to: directory.appendingPathComponent("translation-ai-settings-light.png"))
        try render(VStack(alignment: .leading, spacing: 16) { Text("翻译设置 · 合成演示").font(.title2); TranslationConfigurationView(configuration: config); Spacer(minLength: 0) }.padding(24).background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 660, height: 610), to: directory.appendingPathComponent("translation-ai-settings-dark.png"), scheme: .dark)
        let preview = try config.makeRequest(.translate, content: "Synthetic text approved only inside a fake test.", source: "en", target: "zh-Hans")
        try render(TranslationSendPreview(request: preview, cancel: {}, send: {}), size: NSSize(width: 540, height: 420), to: directory.appendingPathComponent("translation-send-preview.png"))
    }
    private func render<V: View>(_ view: V, size: NSSize, to url: URL, scheme: ColorScheme = .light) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect((bitmap.colorAt(x: bitmap.pixelsWide - 2, y: bitmap.pixelsHigh - 2)?.alphaComponent ?? 0) > 0.99, "A synthetic window snapshot must include its semantic window backdrop: \(url.lastPathComponent)")
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url, options: .atomic)
        #expect(!window.isVisible)
        window.contentView = nil; window.close()
    }
}
struct TranslationEvidenceAI: TranslationAIClient {
    func perform(_ request: TranslationAIRequest) async throws -> TranslationAIResult { .models(["synthetic-reasoning", "synthetic-translate-small", "synthetic-vision"]) }
}
