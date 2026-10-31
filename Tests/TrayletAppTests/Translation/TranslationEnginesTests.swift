import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TrayletApp
import TrayletCore

@Suite("Translation engine row and free engines") @MainActor
struct TranslationEnginesTests {
    private func request(_ action: TranslationAIAction, _ text: String = "Hello", source: String = "en", target: String = "zh-Hans") -> TranslationAIRequest {
        let engine = action.engine
        return .init(id: UUID(), action: action, settings: TranslationConfiguration().settings(for: engine), content: text, source: source, target: target)
    }

    @Test func googlePostsAFormToTheFreeEndpointAndJoinsSegments() async throws {
        let transport = TranslationStubHTTP(status: 200, body: #"[[["你好世界。","Hello world. ",null,null,10],["第二句。","Second.",null,null,3]],null,"en"]"#)
        let sent = request(.googleTranslate, "Hello world. Second.", source: "auto", target: "zh-Hant")
        #expect(try await TranslationOpenAIClient(transport: transport).perform(sent) == .text("你好世界。第二句。"))
        let http = try #require(await transport.requests.first)
        #expect(http.httpMethod == "POST" && http.url?.host == "translate.googleapis.com" && http.url?.path == "/translate_a/single")
        let query = http.url?.query ?? ""
        #expect(query.contains("client=gtx") && query.contains("sl=auto") && query.contains("tl=zh-TW"))
        #expect(http.value(forHTTPHeaderField: "Authorization") == nil)
        let body = String(decoding: try #require(http.httpBody), as: UTF8.self)
        #expect(body == "q=Hello%20world.%20Second.")
    }

    @Test func myMemorySplitsLongTextIntoSmallQueriesAndMapsQuota() async throws {
        let transport = TranslationStubHTTP(status: 200, body: #"{"responseData":{"translatedText":"译"},"responseStatus":200}"#)
        let line = String(repeating: "a", count: 300)
        let sent = request(.myMemoryTranslate, [line, line, line].joined(separator: "\n"))
        let result = try await TranslationOpenAIClient(transport: transport).perform(sent)
        #expect(result == .text("译\n译\n译"))
        let urls = await transport.requests.map { $0.url?.absoluteString ?? "" }
        #expect(urls.count == 3 && urls.allSatisfy { $0.contains("langpair=en%7Czh-CN") || $0.contains("langpair=en|zh-CN") })
        await #expect(throws: TranslationAIFailure.quotaExceeded) {
            try await TranslationOpenAIClient(transport: TranslationStubHTTP(status: 200, body: #"{"quotaFinished":true,"responseData":{"translatedText":"x"},"responseStatus":200}"#)).perform(request(.myMemoryTranslate))
        }
        await #expect(throws: TranslationAIFailure.malformed) {
            try await TranslationOpenAIClient(transport: TranslationStubHTTP(status: 200, body: #"{"responseStatus":403,"responseData":{}}"#)).perform(request(.myMemoryTranslate))
        }
    }

    @Test func pieceSplittingKeepsEveryPieceUnderTheByteLimit() {
        let text = String(repeating: "你好世界。", count: 120) + "\nshort\n" + String(repeating: "x", count: 1000)
        let pieces = TranslationFreeLanguages.pieces(text, maxBytes: 450)
        #expect(pieces.allSatisfy { $0.utf8.count <= 450 } && pieces.count >= 4)
        #expect(pieces.joined().replacingOccurrences(of: "\n", with: "") == text.replacingOccurrences(of: "\n", with: ""))
    }

    @Test func defaultEngineIsFirstOthersFollowOrderAndMaxVisibleClamps() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-order-\(UUID())/translation.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let config = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        for engine in [TranslationEngineChoice.google, .myMemory, .ai] { config.setEnabled(engine, true) }
        #expect(config.availableEngines == [.system, .ai, .google, .myMemory])
        config.move(.myMemory, by: -1)
        #expect(config.availableEngines == [.system, .ai, .myMemory, .google])
        config.engine = .google
        #expect(config.availableEngines == [.google, .system, .ai, .myMemory], "The default engine moves to the front")
        config.maxVisible = 2
        #expect(config.visibleEngines == [.google, .system])
        config.maxVisible = 99; #expect(config.maxVisible == 6)
        config.maxVisible = 0; #expect(config.maxVisible == 1)
        config.maxVisible = 3
        let reopened = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        #expect(reopened.availableEngines == config.availableEngines && reopened.engine == .google && reopened.maxVisible == 3)
        reopened.setEnabled(.google, false)
        #expect(reopened.engine == .system && !reopened.availableEngines.contains(.google))
        reopened.setEnabled(.system, false)
        #expect(reopened.isEnabled(.system), "System translation cannot be removed")
    }

    @Test func uncheckedEnginesCanBeReorderedAndKeepTheirPlaceWhenChecked() {
        let config = TranslationConfiguration(client: RecordingTranslationAI())
        #expect(config.sortableEngines == [.ai, .deepl, .google, .myMemory], "The default engine is pinned and not sortable")
        config.move(.myMemory, by: -1)
        #expect(config.sortableEngines == [.ai, .deepl, .myMemory, .google])
        config.move(.ai, by: -1)
        #expect(config.sortableEngines == [.ai, .deepl, .myMemory, .google], "Cannot move above the pinned default")
        config.move(.google, to: .ai)
        #expect(config.sortableEngines == [.google, .ai, .deepl, .myMemory])
        config.move(.google, to: .myMemory)
        #expect(config.sortableEngines == [.ai, .deepl, .myMemory, .google])
        config.setEnabled(.myMemory, true); config.setEnabled(.ai, true)
        #expect(config.availableEngines == [.system, .ai, .myMemory])
    }

    @Test func dragMovesIgnoreTheDefaultEngineAndPersist() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-drag-\(UUID())/translation.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let config = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        config.setEnabled(.google, true); config.engine = .google
        #expect(config.sortableEngines == [.system, .ai, .deepl, .myMemory])
        config.move(.google, to: .myMemory); config.move(.system, to: .google)
        #expect(config.sortableEngines == [.system, .ai, .deepl, .myMemory])
        config.move(.myMemory, to: .system)
        let reopened = TranslationConfiguration(storageURL: file, client: RecordingTranslationAI())
        #expect(reopened.sortableEngines == [.myMemory, .system, .ai, .deepl])
    }

    @Test func choosingAnotherEngineTranslatesExistingTextAndLaterSendsGoOutDirectly() async throws {
        let client = RecordingTranslationAI()
        let config = TranslationConfiguration(client: client)
        config.setEnabled(.google, true)
        let controller = TranslationController(configuration: config, writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), speech: TranslationFakeSpeech())
        controller.select(.google)
        #expect(controller.selectedEngine == .google)
        controller.flow.input = "Hello"
        controller.select(.system)
        controller.select(.google)
        await controller.submissionTask?.value
        let preview = try #require(controller.preview, "The first send to an engine is confirmed")
        #expect(preview.action == .googleTranslate && controller.flow.phase == .awaitingConfirmation)
        await controller.sendConfirmed(preview)
        #expect(controller.flow.output == "你好。")
        controller.flow.input = "Hello again"
        await controller.submit()
        #expect(controller.preview == nil, "After the first confirmation the engine is used directly")
        #expect(controller.flow.phase == .idle && controller.flow.output == "你好。" && !controller.flow.outputIsCurrent == false)
    }
}

@Suite("Translation language detection") @MainActor
struct TranslationDetectionTests {
    @Test func chineseSourceWithChineseTargetSwitchesTargetToEnglish() {
        let flow = TranslationFlow()
        #expect(flow.target == "zh-Hans")
        flow.input = "今天天气很好，我们一起去公园散步吧。"
        #expect(flow.detectedLanguage == "zh-Hans")
        #expect(flow.target == "en")
        // The user may pick Chinese again; unchanged detection does not override it while editing.
        flow.target = "zh-Hans"
        flow.input = "今天天气很好，我们一起去公园散步吧！"
        #expect(flow.target == "zh-Hans")
    }
    @Test func englishSourceKeepsChineseTargetAndEnglishWithEnglishTargetSwitchesToChinese() {
        let flow = TranslationFlow()
        flow.input = "The weather is lovely today, so let us walk in the park."
        #expect(flow.detectedLanguage == "en" && flow.target == "zh-Hans")
        let other = TranslationFlow(); other.target = "en"
        other.input = "The weather is lovely today, so let us walk in the park."
        #expect(other.target == "zh-Hans")
    }
    @Test func detectionOnlyRunsForAutoSourceAndClearsWithEmptyInput() {
        let flow = TranslationFlow()
        flow.source = "ja"; flow.input = "今日はとても良い天気ですね。"
        #expect(flow.detectedLanguage == nil && flow.target == "zh-Hans")
        flow.source = "auto"
        #expect(flow.detectedLanguage == "ja")
        flow.input = ""
        #expect(flow.detectedLanguage == nil)
    }
    @Test func recognizedScreenshotTextIsDetectedAndRetargeted() throws {
        let flow = TranslationFlow()
        let id = flow.beginRecognition()
        #expect(flow.phase == .recognizing)
        flow.finishRecognition(id, text: "这是一段从截图中识别出来的中文文字。")
        #expect(flow.detectedLanguage == "zh-Hans" && flow.target == "en" && flow.phase == .idle)
    }
}

@Suite("Translation engine icons") @MainActor
struct TranslationEngineIconTests {
    @Test func officialMarkPathsParseIntoTheirViewBox() {
        for (name, data, minimumWidth) in [("google", V2SVGPaths.google, 20.0), ("deepl", V2SVGPaths.deepL, 17.0)] {
            let bounds = V2SVGPathParser.parse(data).boundingRect
            #expect(bounds.minX >= -0.1 && bounds.maxX <= 24.1 && bounds.minY >= -0.1 && bounds.maxY <= 24.1, "\(name) stays inside the 24×24 viewBox")
            #expect(bounds.width >= minimumWidth && bounds.height >= 20, "\(name) is not truncated")
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAYLET_ICON_SNAPSHOT"] != nil))
    func renderIcons() throws {
        let view = HStack(spacing: 12) { ForEach(TranslationEngineChoice.allCases) { TranslationEngineIcon(engine: $0, size: 48) } }.padding(16).background(Color.white)
        let host = NSHostingView(rootView: view); host.frame = NSRect(x: 0, y: 0, width: 400, height: 80)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TRAYLET_ICON_SNAPSHOT"]!))
    }
}
