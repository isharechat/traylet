import AppKit
import SwiftUI
import Foundation
import Testing
@testable import TrayletApp

@Suite("Translation English presentation", .serialized) @MainActor
struct TranslationLocalizationTests {
    @Test func englishTitleAndActionsKeepUserTextUntouched() async throws {
        let configuration = TranslationConfiguration(client: LocalizationLiteralAI())
        let controller = TranslationController(configuration: configuration, writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), speech: TranslationFakeSpeech())
        controller.flow.input = "发送"
        configuration.model = "模型-发送"
        // No suspension while shared UI language is changed, so other MainActor tests cannot interleave.
        let previous = V2Localization.shared.languageCode
        defer { V2Localization.shared.languageCode = previous }
        V2Localization.shared.languageCode = "en"
        #expect(controller.windowTitle == "Translate")
        #expect(V2L("复制原文") == "Copy Source")
        #expect(V2L("复制译文") == "Copy Translation")
        #expect(V2L("清空译文") == "Clear Translation")
        #expect(V2L("备份并恢复默认配置") == "Back Up and Restore Defaults")
        #expect(V2L("发送") == "Send")
        #expect(V2L("获取成功") == "Models Fetched")
        #expect(V2L("连接失败") == "Connection Failed")
        #expect(V2L("从已获取的模型中选择") == "Choose from fetched models")
        #expect(V2L("尚未获取模型") == "No Models Fetched")
        #expect(V2L("先点击“获取模型”获取可用模型列表。") == "Choose “Fetch Models” to load the available model list.")
        #expect(V2L("搜索模型") == "Search Models")
        #expect(V2L("输入模型名称筛选") == "Filter by model name")
        #expect(V2L("没有匹配的模型") == "No Matching Models")
        #expect(controller.flow.input == "发送")
        #expect(configuration.model == "模型-发送")
        let preview = try configuration.makeRequest(.translate, content: controller.flow.input)
        #expect(preview.content == "发送")
        V2Localization.shared.languageCode = "zh-Hans"
        #expect(controller.windowTitle == "翻译")
    }

    @Test(.enabled("Native hidden-window AX probe is opt-in; an empty accessibility tree is an unavailable environment, not passing button coverage.", {
        guard ProcessInfo.processInfo.environment["TRAYLET_REWRITE_TRANSLATION_AX_PROBE"] == "1" else { return false }
        return try await TranslationNativeLanguageProbe.prepare()
    }))
    func nativePreviewExposesEnglishActionsWhenAXTreeIsAvailable() {
        #expect(TranslationNativeLanguageProbe.labels.contains("Send"))
        #expect(TranslationNativeLanguageProbe.labels.contains("Cancel"))
    }
}

@MainActor private enum TranslationNativeLanguageProbe {
    static var labels: [String] = []
    static func prepare() throws -> Bool {
        let previous = V2Localization.shared.languageCode
        defer { V2Localization.shared.languageCode = previous }
        V2Localization.shared.languageCode = "en"
        let configuration = TranslationConfiguration(client: LocalizationLiteralAI())
        configuration.model = "模型-发送"
        let preview = try configuration.makeRequest(.translate, content: "发送")
        _ = NSApplication.shared
        let host = NSHostingView(rootView: TranslationSendPreview(request: preview, cancel: {}, send: {}))
        host.frame = NSRect(x: 0, y: 0, width: 540, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        #expect(!window.isVisible)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = FileManager.default.temporaryDirectory
        try png.write(to: directory.appendingPathComponent("traylet-translation-english-review.png"), options: .atomic)
        labels = (host.accessibilityChildren() ?? []).flatMap(accessibleLabels)
        let diagnostic: [String: Any] = ["issue": labels.isEmpty ? "environmentUnavailable: hidden NSHostingView accessibility tree is empty" : "none", "isVisible": window.isVisible, "labels": labels]
        try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("traylet-translation-english-ax-probe.json"), options: .atomic)
        if labels.isEmpty { print("AX probe unavailable: hidden NSHostingView returned an empty tree; native AX/VoiceOver assertions are skipped and remain unverified.") }
        return !labels.isEmpty
    }
    private static func accessibleLabels(_ node: Any) -> [String] {
        guard let element = node as? any NSAccessibilityProtocol else { return [] }
        return [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String].compactMap { $0 } + (element.accessibilityChildren() ?? []).flatMap(accessibleLabels)
    }
}

struct LocalizationLiteralAI: TranslationAIClient {
    func perform(_ request: TranslationAIRequest) async throws -> TranslationAIResult { .text("发送") }
}
