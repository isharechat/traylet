import AppKit
import Testing
import TrayletCore
@testable import TrayletApp

@Suite("Clipboard OCR Translation Bridge") @MainActor struct ClipboardTranslationBridgeTests {
    @Test func historyImageBecomesCorrectableSourceAndSendsOnlyAfterExplicitConfirmation() async throws {
        let fixture = try await HistoryOCRFixture()
        defer { fixture.close() }
        let original = try #require(fixture.feature.controller.selectedEntry)
        let prepare = try #require(fixture.feature.recognizeImage(original.id, itemIndex: 1))
        await prepare.value
        #expect(fixture.presentation.count == 1 && fixture.translation.flow.phase == .recognizing)
        #expect(await fixture.client.requests.isEmpty)
        await fixture.recognizer.waitForCalls(1)
        await fixture.recognizer.resolve(0, .success("Recognized synthetic text"))
        try await eventually { fixture.translation.flow.input == "Recognized synthetic text" }
        #expect(fixture.translation.preview == nil && fixture.translation.systemWork == nil)
        #expect(await fixture.client.requests.isEmpty)
        fixture.translation.flow.input = "Corrected synthetic text"
        await fixture.translation.submit()
        let preview = try #require(fixture.translation.preview)
        #expect(preview.content == "Corrected synthetic text")
        #expect(await fixture.client.requests.isEmpty)
        await fixture.translation.sendConfirmed(preview)
        #expect(await fixture.client.requests.map(\.content) == ["Corrected synthetic text"])
        #expect(fixture.translation.flow.output == "合成翻译结果")
        #expect(fixture.feature.controller.entries == [original] && fixture.writer.writes.isEmpty)
        #expect(fixture.presentation.panel?.isVisible == false)
        await fixture.feature.shutdownAndWait()
    }
    @Test func recognitionWithdrawnBeforeItsTaskRunsDoesNotEnterTheRecognizer() async throws {
        let recognizer = ImmediateHistoryRecognizer()
        let controller = TranslationController(configuration: TranslationConfiguration(client: HistoryOCRTranslationClient()), writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), recognizer: recognizer, speech: TranslationFakeSpeech(), presentWindow: { _ in })
        controller.flow.input = "Previous source"
        let work = controller.flow.begin(engine: .system)!
        controller.flow.complete(work, text: "保留原有译文")
        let task = controller.beginImageInput(try EditingTests.fixture())
        controller.cancel()
        await task.value
        #expect(await recognizer.calls == 0)
        #expect(controller.flow.input == "Previous source" && controller.flow.output == "保留原有译文")
        #expect(controller.flow.phase == .idle)
    }
    @Test func historyOCRReusesThePreparedPixelsInsteadOfDecodingThePNGAgain() async throws {
        let fixture = try await HistoryOCRFixture()
        defer { fixture.close() }
        let id = try #require(fixture.feature.controller.selectedID)
        await fixture.feature.recognizeImage(id, itemIndex: 1)?.value
        await fixture.recognizer.waitForCalls(1)
        #expect(await fixture.recognizer.receivedPixels === fixture.prepared.pixels)
        await fixture.recognizer.resolve(0, .success("Prepared pixel source"))
        try await eventually { fixture.translation.flow.input == "Prepared pixel source" }
    }
    @Test(arguments: [false, true]) func overlongOCRPreservesExistingTextsAndOffersAClearRecovery(thrown: Bool) async throws {
        let controller = TranslationController(configuration: TranslationConfiguration(client: HistoryOCRTranslationClient()), writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), recognizer: OverlongHistoryRecognizer(thrown: thrown), speech: TranslationFakeSpeech(), presentWindow: { _ in })
        controller.flow.input = "Previous source"
        let prior = try #require(controller.flow.begin(engine: .system))
        controller.flow.complete(prior, text: "保留的译文")
        await controller.beginImageInput(try EditingTests.fixture()).value
        let keptOriginal = controller.flow.input == "Previous source"
        #expect(keptOriginal && controller.flow.output == "保留的译文" && controller.flow.outputIsCurrent)
        #expect(controller.flow.phase == .failed("识别文字过长，请缩小图片区域或直接输入。"))
        #expect(controller.preview == nil && controller.systemWork == nil)
    }
    @Test func nativeTitlebarCloseRevokesThePreviousWindowsSendConfirmation() async throws {
        let fixture = try await HistoryOCRFixture()
        defer { fixture.close() }
        fixture.translation.present(text: "First synthetic source")
        await fixture.translation.submit()
        await fixture.translation.sendConfirmed(try #require(fixture.translation.preview))
        let panel = try #require(fixture.presentation.panel)
        let sentBeforeClose = await fixture.client.requests.count
        #expect(!panel.isVisible && sentBeforeClose == 1)
        panel.close() // Real delegate notification on our own hidden window.
        fixture.translation.present(text: "New synthetic source")
        await fixture.translation.submit()
        #expect(fixture.translation.preview?.content == "New synthetic source")
        #expect(await fixture.client.requests.count == 1)
    }
    @Test(arguments: ["query", "dismiss", "delete", "shutdown", "selection", "busy"])
    func preparationWithdrawnOrTargetBusyCannotOpenOCR(_ change: String) async throws {
        let gate = HistoryPreparationGate()
        let fixture = try await HistoryOCRFixture(imageEditing: ClipboardImageEditing(prepare: { _ in await gate.wait() }))
        defer { fixture.close() }
        let original = try #require(fixture.feature.controller.selectedEntry)
        let task = try #require(fixture.feature.recognizeImage(original.id, itemIndex: 1))
        #expect(fixture.feature.recognizeImage(original.id, itemIndex: 1) == nil)
        await gate.waitUntilPending()
        switch change {
        case "query": fixture.feature.controller.query = "missing"
        case "dismiss": fixture.feature.dismiss()
        case "delete": await fixture.feature.controller.delete(original.id)
        case "shutdown": await fixture.feature.shutdownAndWait()
        case "selection": fixture.feature.controller.selectedID = nil
        default: fixture.presentation.allowed = false
        }
        await gate.finish(fixture.prepared); await task.value
        #expect(fixture.presentation.count == 0 && !fixture.feature.imageEditing.isPreparing)
        #expect(await fixture.recognizer.calls == 0)
        #expect(fixture.writer.writes.isEmpty)
        #expect(await fixture.client.requests.isEmpty)
    }
    @Test(arguments: ["cancel", "close", "nativeClose", "input", "language", "configuration"])
    func handedOffOCRRejectsLateTextAfterWithdrawal(_ change: String) async throws {
        let fixture = try await HistoryOCRFixture()
        defer { fixture.close() }
        fixture.seedPreviousText()
        await fixture.feature.recognizeImage(try #require(fixture.feature.controller.selectedID), itemIndex: 1)?.value
        let reading = try #require(fixture.translation.imageInputTask)
        await fixture.recognizer.waitForCalls(1)
        switch change {
        case "cancel": fixture.translation.cancel()
        case "close": fixture.translation.close()
        case "nativeClose": fixture.presentation.panel?.close()
        case "input": fixture.translation.flow.input = "Manual correction"
        case "language": fixture.translation.flow.target = "ja"
        default: fixture.translation.configuration.model = "new-synthetic-model"
        }
        await fixture.recognizer.resolve(0, .success("Obsolete text")); await reading.value
        #expect(fixture.translation.flow.input == (change == "input" ? "Manual correction" : "Previous source"))
        #expect(fixture.translation.flow.output == "之前的译文" && fixture.translation.flow.phase == .idle)
        #expect(fixture.translation.preview == nil && fixture.translation.systemWork == nil && fixture.writer.writes.isEmpty)
        #expect(await fixture.client.requests.isEmpty)
    }
    @Test func aFailedImageCanBeChosenAgainWithoutLosingItsOriginal() async throws {
        let fixture = try await HistoryOCRFixture()
        defer { fixture.close() }
        let original = try #require(fixture.feature.controller.selectedEntry)
        fixture.seedPreviousText()
        await fixture.feature.recognizeImage(original.id, itemIndex: 1)?.value
        let first = try #require(fixture.translation.imageInputTask)
        await fixture.recognizer.waitForCalls(1)
        await fixture.recognizer.resolve(0, .failure(FeatureIssue.unavailable("synthetic private details"))); await first.value
        #expect(fixture.translation.flow.input == "Previous source" && fixture.translation.flow.output == "之前的译文")
        #expect(fixture.translation.flow.phase == .failed("本机文字识别失败，请重新截图或直接输入。"))
        await fixture.feature.recognizeImage(original.id, itemIndex: 1)?.value
        let second = try #require(fixture.translation.imageInputTask)
        await fixture.recognizer.waitForCalls(2)
        await fixture.recognizer.resolve(1, .success("Recovered source")); await second.value
        #expect(fixture.translation.flow.input == "Recovered source" && fixture.translation.flow.phase == .idle)
        #expect(fixture.feature.controller.entries == [original] && fixture.writer.writes.isEmpty)
        #expect(await fixture.client.requests.isEmpty)
    }
    @Test func theNewImageOwnsInputWhenTheOldImageFinishesLast() async throws {
        let fixture = try await HistoryOCRFixture()
        defer { fixture.close() }
        let id = try #require(fixture.feature.controller.selectedID)
        await fixture.feature.recognizeImage(id, itemIndex: 1)?.value
        let old = try #require(fixture.translation.imageInputTask)
        await fixture.recognizer.waitForCalls(1)
        await fixture.feature.recognizeImage(id, itemIndex: 1)?.value
        let new = try #require(fixture.translation.imageInputTask)
        await fixture.recognizer.waitForCalls(2)
        await fixture.recognizer.resolve(1, .success("Current image")); await new.value
        await fixture.recognizer.resolve(0, .success("Obsolete image")); await old.value
        #expect(fixture.translation.flow.input == "Current image" && fixture.translation.flow.phase == .idle)
        #expect(fixture.presentation.count == 2 && fixture.writer.writes.isEmpty)
        #expect(await fixture.client.requests.isEmpty)
    }
    @Test func recognitionMustFinishOrBeCancelledBeforeTranslatingTheRetainedSource() async throws {
        let fixture = try await HistoryOCRFixture()
        defer { fixture.close() }
        fixture.translation.configuration.setEnabled(.google, true)
        fixture.seedPreviousText()
        await fixture.feature.recognizeImage(try #require(fixture.feature.controller.selectedID), itemIndex: 1)?.value
        let reading = try #require(fixture.translation.imageInputTask)
        await fixture.recognizer.waitForCalls(1)
        fixture.translation.startSubmission()
        await fixture.translation.submissionTask?.value
        fixture.translation.select(.google)
        await fixture.translation.submissionTask?.value
        await fixture.translation.submit()
        #expect(fixture.translation.flow.phase == .recognizing)
        #expect(fixture.translation.preview == nil && fixture.translation.systemWork == nil)
        #expect(fixture.translation.selectedEngine == .ai)
        await fixture.recognizer.resolve(0, .success("Current image source")); await reading.value
        #expect(fixture.translation.flow.input == "Current image source")
        #expect(await fixture.client.requests.isEmpty)
    }
    @Test func smallestWindowKeepsLocalizedLanguagesAndTranslateActionVisible() async throws {
        let original = V2Localization.shared.languageCode
        defer { V2Localization.shared.languageCode = original }
        V2Localization.shared.languageCode = "zh-Hans"
        let fixture = try await HistoryOCRFixture()
        defer { fixture.close() }
        fixture.translation.present(text: "Synthetic source")
        let panel = try #require(fixture.presentation.panel)
        let chinese = panel.minSize.width
        V2Localization.shared.languageCode = "en"
        try await Task.sleep(for: .milliseconds(30))
        // At the former 502pt minimum the actual English action rendered as “Tr…”.
        #expect(panel.minSize.width >= 530)
        #expect(panel.minSize.width > chinese + 30)
        let twoEngines = panel.minSize.width
        fixture.translation.configuration.maxVisible = 6
        fixture.translation.configuration.setEnabled(.google, true)
        fixture.translation.configuration.setEnabled(.deepl, true)
        fixture.translation.configuration.setEnabled(.myMemory, true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(panel.minSize.width >= twoEngines + 100)
        #expect(panel.contentLayoutRect.width >= panel.minSize.width)
        #expect(fixture.translation.preview == nil && fixture.translation.systemWork == nil)
        #expect(await fixture.client.requests.isEmpty)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAYLET_HISTORY_OCR_EVIDENCE_DIR"] != nil))
    func renderHiddenHistoryOCRProcessingCorrectionAndFailure() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TRAYLET_HISTORY_OCR_EVIDENCE_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let originalLanguage = V2Localization.shared.languageCode
        let originalAppearance = NSApp.appearance
        let originalGlass = V2AppearanceState.shared.glassEnabled
        defer {
            V2Localization.shared.languageCode = originalLanguage
            V2AppearanceState.shared.glassEnabled = originalGlass
            NSApp.appearance = originalAppearance
        }
        // Hidden cacheDisplay cannot composite WindowServer glass. Capture the real supported solid mode.
        V2AppearanceState.shared.glassEnabled = false
        for dark in [false, true] {
            V2Localization.shared.languageCode = dark ? "en" : "zh-Hans"
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let fixture = try await HistoryOCRFixture()
            defer { fixture.close() }
            fixture.seedPreviousText()
            let id = try #require(fixture.feature.controller.selectedID)
            await fixture.feature.recognizeImage(id, itemIndex: 1)?.value
            let reading = try #require(fixture.translation.imageInputTask)
            await fixture.recognizer.waitForCalls(1)
            let panel = try #require(fixture.presentation.panel)
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            panel.setContentSize(NSSize(width: 600, height: 540))
            let suffix = dark ? "dark-en" : "light-zh"
            try await snapshot(panel, to: output.appendingPathComponent("history-ocr-processing-\(suffix).png"))
            #expect(fixture.translation.flow.phase == .recognizing)
            await fixture.recognizer.resolve(0, .success("Synthetic recognized source.\nThis text can be corrected before translation.")); await reading.value
            fixture.translation.flow.input = "Corrected synthetic source.\nNo text is sent automatically."
            panel.setContentSize(NSSize(width: panel.minSize.width, height: 440))
            try await snapshot(panel, to: output.appendingPathComponent("history-ocr-correction-\(suffix).png"))
            await fixture.feature.recognizeImage(id, itemIndex: 1)?.value
            let failed = try #require(fixture.translation.imageInputTask)
            await fixture.recognizer.waitForCalls(2)
            await fixture.recognizer.resolve(1, .failure(FeatureIssue.invalidInput("识别文字过长。"))); await failed.value
            try await snapshot(panel, to: output.appendingPathComponent("history-ocr-error-\(suffix).png"))
            #expect(fixture.translation.preview == nil && fixture.translation.systemWork == nil)
            #expect(await fixture.client.requests.isEmpty)
            await fixture.feature.shutdownAndWait()
        }
    }
    /// Cache the same mounted native window throughout OCR; destroying a duplicate view would cancel it.
    private func snapshot(_ panel: NSPanel, to url: URL) async throws {
        let view = try #require(panel.contentView)
        view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)); view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let pixels = try #require(bitmap.cgImage)
        let context = try #require(CGContext(data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        panel.effectiveAppearance.performAsCurrentDrawingAppearance { context.setFillColor(NSColor.windowBackgroundColor.cgColor) }
        context.fill(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        let image = try #require(context.makeImage())
        let png = try EditingRenderer.encode(image).pngData
        #expect(png.count > 4000 && !panel.isVisible && panel.attachedSheet?.isVisible != true)
        try png.write(to: url)
    }
    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }
}

@MainActor private final class HistoryOCRFixture {
    let source = MemoryClipboardSource(), writer = MemoryClipboardWriter()
    let client = HistoryOCRTranslationClient(), recognizer = HistoryOCRRecognizer()
    let presentation = HistoryOCRPresentation()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-history-ocr-" + UUID().uuidString)
    let feature: ClipboardFeature, translation: TranslationController
    let prepared: ClipboardPreparedImage
    let bridge: ClipboardTranslationBridge
    init(imageEditing: ClipboardImageEditing? = nil) async throws {
        _ = NSApplication.shared
        let configuration = TranslationConfiguration(client: client)
        configuration.engine = .ai; configuration.model = "synthetic-model"
        let presentation = presentation
        translation = TranslationController(configuration: configuration, writer: TranslationFakeWriter(), availability: TranslationFakeAvailability(), recognizer: recognizer, speech: TranslationFakeSpeech(),
                                            presentWindow: { presentation.count += 1; presentation.panel = $0 })
        let image = try EditingTests.fixture()
        let prepared = try await ClipboardImageDecoder.prepare(image.pngData); self.prepared = prepared
        feature = ClipboardFeature(directory: directory, source: source, writer: writer, imageEditing: imageEditing ?? ClipboardImageEditing(prepare: { _ in prepared }), presentWindow: { _ in }, dismissWindow: { $0.orderOut(nil) })
        bridge = ClipboardTranslationBridge(clipboard: feature, translation: translation, canPresent: { presentation.allowed })
        await feature.start(poll: false)
        source.value = .init(generation: 1, items: [.text("original synthetic text"), .init(representations: ["public.png": image.pngData])], application: "synthetic.app")
        await feature.controller.refresh()
    }
    func seedPreviousText() {
        translation.flow.input = "Previous source"
        let work = translation.flow.begin(engine: .system)!
        translation.flow.complete(work, text: "之前的译文")
    }
    func close() { translation.close(); feature.shutdown(); try? FileManager.default.removeItem(at: directory) }
}
@MainActor private final class HistoryOCRPresentation { var count = 0; var panel: NSPanel?; var allowed = true }
private actor HistoryOCRTranslationClient: TranslationAIClient {
    private(set) var requests: [TranslationAIRequest] = []
    func perform(_ request: TranslationAIRequest) async throws -> TranslationAIResult {
        requests.append(request); return .text("合成翻译结果")
    }
}
private actor ImmediateHistoryRecognizer: TranslationRecognizing {
    private(set) var calls = 0
    func recognize(_ image: RasterImage) async throws -> String { calls += 1; return "unwanted recognition" }
}
private struct OverlongHistoryRecognizer: TranslationRecognizing {
    let thrown: Bool
    func recognize(_ image: RasterImage) async throws -> String {
        if thrown { throw FeatureIssue.invalidInput("识别文字过长。") }
        return String(repeating: "文", count: 43_691) // 131073 UTF-8 bytes, not characters.
    }
}
private actor HistoryOCRRecognizer: TranslationRecognizing {
    private var pending: [Int: CheckedContinuation<String, any Error>] = [:]
    private var count = 0
    var calls: Int { count }
    private(set) var receivedPixels: CGImage?
    func recognize(_ image: RasterImage, decoded: CGImage) async throws -> String {
        receivedPixels = decoded
        return try await recognize(image)
    }
    func recognize(_ image: RasterImage) async throws -> String {
        let id = count; count += 1
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    func waitForCalls(_ expected: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while count < expected, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(count >= expected)
    }
    func resolve(_ id: Int, _ result: Result<String, any Error>) { pending.removeValue(forKey: id)?.resume(with: result) }
}
private actor HistoryPreparationGate {
    private var continuation: CheckedContinuation<ClipboardPreparedImage, Never>?
    func wait() async -> ClipboardPreparedImage { await withCheckedContinuation { continuation = $0 } }
    func waitUntilPending() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while continuation == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(continuation != nil)
    }
    func finish(_ image: ClipboardPreparedImage) { continuation?.resume(returning: image); continuation = nil }
}
