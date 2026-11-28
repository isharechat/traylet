import AppKit
import Foundation
import Testing
import TrayletCore
@testable import TrayletApp

@Suite("Clipboard Category and Image Preview") @MainActor struct ClipboardCategoryAndPreviewTests {
    @Test func categoryFilterFiltersEntriesCombinedWithFavoritesAndQuery() async throws {
        let source = MemoryClipboardSource()
        let controller = ClipboardController(source: source, writer: MemoryClipboardWriter())
        await controller.enable()

        source.value = .init(generation: 1, items: [.text("hello world note")], application: "com.example.Notes")
        await controller.refresh()
        source.value = .init(generation: 2, items: [.text("https://example.com/docs")], application: "com.example.Safari")
        await controller.refresh()
        let imageBytes = try makePNG(width: 80, height: 60)
        var imageItem = ClipboardContent.text("screenshot caption")
        imageItem.representations["public.png"] = imageBytes
        source.value = .init(generation: 3, items: [imageItem], application: "com.example.Preview")
        await controller.refresh()

        let textEntry = try #require(controller.entries.first { $0.plainText == "hello world note" })
        let linkEntry = try #require(controller.entries.first { $0.plainText == "https://example.com/docs" })
        let imageEntry = try #require(controller.entries.first { $0.imageData != nil })

        #expect(controller.kindFilter == .all)
        #expect(controller.filteredEntries.count == 3)

        controller.kindFilter = .text
        #expect(controller.filteredEntries.map(\.id) == [textEntry.id])

        controller.kindFilter = .link
        #expect(controller.filteredEntries.map(\.id) == [linkEntry.id])

        controller.kindFilter = .image
        #expect(controller.filteredEntries.map(\.id) == [imageEntry.id])

        // Combine category filter with favoritesOnly and query.
        await controller.toggleFavorite(imageEntry.id)
        await controller.toggleFavorite(linkEntry.id)
        controller.favoritesOnly = true
        #expect(controller.filteredEntries.map(\.id) == [imageEntry.id])

        controller.kindFilter = .all
        controller.query = "example.com"
        #expect(controller.filteredEntries.map(\.id) == [linkEntry.id])

        controller.kindFilter = .text
        #expect(controller.filteredEntries.isEmpty)
        await controller.shutdown()
    }

    @Test func switchingCategoryReconcilesSelectionAndGatesFavoriteReorder() async throws {
        let source = MemoryClipboardSource()
        let controller = ClipboardController(source: source, writer: MemoryClipboardWriter())
        await controller.enable()

        source.value = .init(generation: 1, items: [.text("alpha text")], application: "com.example.Notes")
        await controller.refresh()
        source.value = .init(generation: 2, items: [.text("https://example.org")], application: "com.example.Safari")
        await controller.refresh()

        let textID = try #require(controller.entries.first { $0.plainText == "alpha text" }?.id)
        let linkID = try #require(controller.entries.first { $0.plainText == "https://example.org" }?.id)
        await controller.toggleFavorite(textID)
        await controller.toggleFavorite(linkID)

        controller.selectedID = textID
        controller.kindFilter = .link
        #expect(controller.selectedID == nil)

        // Reordering favorites is disallowed while filtered to a non-.all category.
        let reversed = [linkID, textID]
        #expect(!(await controller.reorderFavorites(reversed)))
        #expect(controller.orderedFavoriteIDs == [textID, linkID])

        controller.kindFilter = .all
        #expect(await controller.reorderFavorites(reversed))
        #expect(controller.orderedFavoriteIDs == reversed)
        await controller.shutdown()
    }

    @Test func dismissResetsCategoryFilterToAll() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-clipboard-filter-reset-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let feature = ClipboardFeature(
            directory: directory,
            source: MemoryClipboardSource(),
            writer: MemoryClipboardWriter(),
            presentWindow: { _ in },
            dismissWindow: { _ in },
            presentPreviewWindow: { _ in },
            dismissPreviewWindow: { _ in }
        )
        await feature.start(poll: false)
        feature.present()
        feature.controller.kindFilter = .image
        #expect(feature.controller.kindFilter == .image)

        feature.dismiss()
        #expect(feature.controller.kindFilter == .all)
        await feature.shutdownAndWait()
    }

    @Test func imagePreviewLifecycleOpensClosesAndTracksDeletionAndDismissal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-clipboard-preview-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared

        var mainDismissals = 0
        var previewPresentations = 0
        var previewDismissals = 0
        let source = MemoryClipboardSource()
        let feature = ClipboardFeature(
            directory: directory,
            source: source,
            writer: MemoryClipboardWriter(),
            presentWindow: { _ in },
            dismissWindow: { _ in mainDismissals += 1 },
            presentPreviewWindow: { _ in previewPresentations += 1 },
            dismissPreviewWindow: { _ in previewDismissals += 1 }
        )
        await feature.start(poll: false)

        source.value = .init(generation: 1, items: [.text("plain text entry")], application: "com.example.Notes")
        await feature.controller.refresh()
        var imageContent = ClipboardContent(representations: ["public.png": try makePNG(width: 120, height: 90)])
        imageContent.representations[ClipboardContent.textType] = Data("caption".utf8)
        source.value = .init(generation: 2, items: [imageContent], application: "com.example.Canvas")
        await feature.controller.refresh()

        let textID = try #require(feature.controller.entries.first { $0.imageData == nil }?.id)
        let imageID = try #require(feature.controller.entries.first { $0.imageData != nil }?.id)

        // Non-image entries never open the image preview.
        feature.openImagePreview(textID)
        #expect(!feature.isImagePreviewOpen)
        #expect(previewPresentations == 0)

        // Image entry opens preview and blocks resign-key dismissal while open.
        feature.openImagePreview(imageID)
        #expect(feature.isImagePreviewOpen)
        #expect(feature.previewedImageEntryID == imageID)
        #expect(feature.imagePreviewPanelForTesting != nil)
        #expect(previewPresentations == 1)
        #expect(!feature.canDismissOnResignKey())

        // Closing preview closes only the preview, not the main clipboard window.
        feature.closeImagePreview()
        #expect(!feature.isImagePreviewOpen)
        #expect(feature.previewedImageEntryID == nil)
        #expect(previewDismissals == 1)
        #expect(mainDismissals == 0)
        #expect(feature.canDismissOnResignKey())

        // Deleting the previewed entry automatically closes the preview.
        feature.openImagePreview(imageID)
        #expect(feature.isImagePreviewOpen)
        await feature.controller.delete(imageID)
        try await Task.sleep(for: .milliseconds(30))
        #expect(!feature.isImagePreviewOpen)

        // Dismissing the clipboard window also closes an open preview.
        source.value = .init(generation: 3, items: [imageContent], application: "com.example.Canvas")
        await feature.controller.refresh()
        let secondImageID = try #require(feature.controller.entries.first { $0.imageData != nil }?.id)
        feature.openImagePreview(secondImageID)
        #expect(feature.isImagePreviewOpen)
        feature.dismiss()
        #expect(!feature.isImagePreviewOpen)

        await feature.shutdownAndWait()
    }

    @Test func zoomClampsBoundsAndComputesPercentages() {
        #expect(ClipboardImageZoom.clamped(0.05) == ClipboardImageZoom.minScale)
        #expect(ClipboardImageZoom.clamped(10.0) == ClipboardImageZoom.maxScale)
        #expect(ClipboardImageZoom.clamped(.nan) == 1.0)

        let fit = ClipboardImageZoom.fit
        #expect(fit.displayPercentage(currentFitScale: 0.5) == 50)
        #expect(fit.zoomIn(currentFitScale: 0.5) == .scale(0.625))
        #expect(fit.zoomOut(currentFitScale: 0.5) == .scale(0.4))

        let maxZoom = ClipboardImageZoom.scale(ClipboardImageZoom.maxScale)
        #expect(maxZoom.zoomIn() == .scale(ClipboardImageZoom.maxScale))
        let minZoom = ClipboardImageZoom.scale(ClipboardImageZoom.minScale)
        #expect(minZoom.zoomOut() == .scale(ClipboardImageZoom.minScale))
        #expect(ClipboardImageZoom.scale(1.0).displayPercentage() == 100)
    }

    @Test func previewWindowSizesToNaturalDimensionsAndClampsPanOffsets() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Normal Retina screenshot (800x600 px @ 2x -> 400x300 pt) displays at 1:1 natural size + chrome.
        let natural = ClipboardFeature.preferredPreviewSize(
            forPixelSize: CGSize(width: 800, height: 600),
            backingScale: 2.0,
            screenVisibleFrame: screen
        )
        #expect(natural == NSSize(width: 424, height: 406))

        // Tiny icon clamps safely to minimum window size so controls remain usable.
        let tiny = ClipboardFeature.preferredPreviewSize(
            forPixelSize: CGSize(width: 100, height: 80),
            backingScale: 2.0,
            screenVisibleFrame: screen
        )
        #expect(tiny == NSSize(width: 360, height: 260))

        // Oversized image scales down proportionally within screen budget while preserving aspect ratio.
        let oversized = ClipboardFeature.preferredPreviewSize(
            forPixelSize: CGSize(width: 6000, height: 3000),
            backingScale: 1.0,
            screenVisibleFrame: screen
        )
        #expect(oversized.width <= floor(screen.width * 0.88))
        #expect(oversized.height <= floor(screen.height * 0.86))

        // Zoomed-in image can pan across its full overflow plus 16pt breathing room.
        let pannedIn = ClipboardImageZoom.clampedPanOffset(
            proposed: CGSize(width: 500, height: -400),
            imageSize: CGSize(width: 1000, height: 800),
            viewportSize: CGSize(width: 600, height: 400)
        )
        #expect(pannedIn == CGSize(width: 216, height: -216))

        // Zoomed-out image can still be dragged cleanly within the viewport bounds without leaving screen.
        let pannedOut = ClipboardImageZoom.clampedPanOffset(
            proposed: CGSize(width: 300, height: -300),
            imageSize: CGSize(width: 200, height: 150),
            viewportSize: CGSize(width: 500, height: 450)
        )
        #expect(pannedOut == CGSize(width: 150, height: -150))
    }

    @Test func textLinkageOpensTranslationAndSubmitsAndRejectsBlankEntries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-clipboard-text-link-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared

        var clipboardDismissals = 0
        var translationPresentations = 0
        var canPresent = true

        let source = MemoryClipboardSource()
        let feature = ClipboardFeature(
            directory: directory,
            source: source,
            writer: MemoryClipboardWriter(),
            presentWindow: { _ in },
            dismissWindow: { _ in clipboardDismissals += 1 },
            presentPreviewWindow: { _ in },
            dismissPreviewWindow: { _ in }
        )
        let client = RecordingTranslationAI()
        let translationConfig = TranslationConfiguration(client: client)
        translationConfig.engine = .ai
        translationConfig.model = "synthetic-model"
        let translation = TranslationController(
            configuration: translationConfig,
            writer: TranslationFakeWriter(),
            availability: TranslationFakeAvailability(),
            speech: TranslationFakeSpeech(),
            presentWindow: { _ in translationPresentations += 1 }
        )
        let bridge = ClipboardTranslationBridge(
            clipboard: feature,
            translation: translation,
            canPresent: { canPresent }
        )
        defer { withExtendedLifetime(bridge) {} }

        await feature.start(poll: false)
        feature.present()
        source.value = .init(generation: 1, items: [.text("   \n  ")], application: "com.example.Notes")
        await feature.controller.refresh()
        source.value = .init(generation: 2, items: [.text("Translate this sentence")], application: "com.example.Notes")
        await feature.controller.refresh()

        let blankID = try #require(feature.controller.entries.first { $0.plainText == "   \n  " }?.id)
        let textID = try #require(feature.controller.entries.first { $0.plainText == "Translate this sentence" }?.id)

        // Blank text or unavailable bridge must not open translation or dismiss clipboard.
        #expect(!feature.translateText(blankID))
        canPresent = false
        #expect(!feature.translateText(textID))
        #expect(translationPresentations == 0 && clipboardDismissals == 0)

        canPresent = true
        #expect(feature.translateText(textID))
        #expect(translationPresentations == 1)
        #expect(clipboardDismissals == 1)
        #expect(translation.flow.input == "Translate this sentence")

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await client.calls == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await client.calls == 1)
        #expect(translation.flow.output == "你好。")

        // Filtered-out entry cannot be linked.
        feature.controller.query = "no-match"
        #expect(!feature.translateText(textID))

        translation.close()
        await feature.shutdownAndWait()
    }

    @Test func linkActionValidatesSchemeAndRespectsOpenResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-clipboard-open-link-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared

        var clipboardDismissals = 0
        var openedURLs: [URL] = []
        var openShouldSucceed = false

        let source = MemoryClipboardSource()
        let feature = ClipboardFeature(
            directory: directory,
            source: source,
            writer: MemoryClipboardWriter(),
            presentWindow: { _ in },
            dismissWindow: { _ in clipboardDismissals += 1 },
            presentPreviewWindow: { _ in },
            dismissPreviewWindow: { _ in }
        )
        feature.openURL = { url in
            openedURLs.append(url)
            return openShouldSucceed
        }

        await feature.start(poll: false)
        feature.present()
        source.value = .init(generation: 1, items: [.text("file:///etc/passwd")], application: "com.example.Notes")
        await feature.controller.refresh()
        source.value = .init(generation: 2, items: [.text("https://example.com/guide?tab=1")], application: "com.example.Safari")
        await feature.controller.refresh()

        let fileEntry = try #require(feature.controller.entries.first { $0.plainText == "file:///etc/passwd" })
        let linkEntry = try #require(feature.controller.entries.first { $0.plainText == "https://example.com/guide?tab=1" })

        #expect(ClipboardDisplay(fileEntry).kind == .text)
        #expect(ClipboardDisplay(fileEntry).linkURL == nil)
        #expect(!feature.openLink(fileEntry.id))
        #expect(openedURLs.isEmpty)

        #expect(ClipboardDisplay(linkEntry).kind == .link)
        #expect(ClipboardDisplay(linkEntry).linkURL == URL(string: "https://example.com/guide?tab=1"))

        // If openURL fails, clipboard stays open.
        openShouldSucceed = false
        #expect(!feature.openLink(linkEntry.id))
        #expect(openedURLs.count == 1)
        #expect(clipboardDismissals == 0)

        // When openURL succeeds, clipboard dismisses cleanly.
        openShouldSucceed = true
        #expect(feature.openLink(linkEntry.id))
        #expect(openedURLs.last == URL(string: "https://example.com/guide?tab=1"))
        #expect(clipboardDismissals == 1)

        await feature.shutdownAndWait()
    }

    @Test func imageLinkageRoutesStandaloneOCRAndScreenshotTranslationIndependently() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-clipboard-image-linkage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared

        var clipboardDismissals = 0
        var translationPresentations = 0
        var ocrPresentations = 0
        var canPresent = true

        let imageBytes = try makePNG(width: 64, height: 48)
        let prepared = try await ClipboardImageDecoder.prepare(imageBytes)

        let source = MemoryClipboardSource()
        let feature = ClipboardFeature(
            directory: directory,
            source: source,
            writer: MemoryClipboardWriter(),
            imageEditing: ClipboardImageEditing(prepare: { _ in prepared }),
            presentWindow: { _ in },
            dismissWindow: { _ in clipboardDismissals += 1 },
            presentPreviewWindow: { _ in },
            dismissPreviewWindow: { _ in }
        )

        let translationConfig = TranslationConfiguration(client: RecordingTranslationAI())
        let translation = TranslationController(
            configuration: translationConfig,
            writer: TranslationFakeWriter(),
            availability: TranslationFakeAvailability(),
            recognizer: LinkageVisionRecognizer(result: "Translated OCR Text"),
            speech: TranslationFakeSpeech(),
            presentWindow: { _ in translationPresentations += 1 }
        )
        let ocr = OCRController(
            configuration: OCRConfiguration(),
            visionRecognizer: LinkageVisionRecognizer(result: "Standalone OCR Result"),
            aiRecognizer: LinkageAIRecognizer(result: "AI"),
            writer: LinkageOCRWriter(),
            speech: TranslationFakeSpeech(),
            presentWindow: { _ in ocrPresentations += 1 }
        )
        let bridge = ClipboardTranslationBridge(
            clipboard: feature,
            translation: translation,
            ocr: ocr,
            canPresent: { canPresent }
        )
        defer { withExtendedLifetime(bridge) {} }

        await feature.start(poll: false)
        feature.present()
        source.value = .init(generation: 1, items: [ClipboardContent(representations: ["public.png": imageBytes])], application: "com.example.Preview")
        await feature.controller.refresh()
        let imageID = try #require(feature.controller.entries.first?.id)

        // When canPresent is false, OCR linkage reports unavailable and does not run.
        canPresent = false
        #expect(feature.openOCRImage(imageID, itemIndex: 0) == nil)
        #expect(feature.imageEditing.message != nil)
        #expect(ocrPresentations == 0 && translationPresentations == 0)

        // Standalone OCR route.
        canPresent = true
        let ocrTask = try #require(feature.openOCRImage(imageID, itemIndex: 0))
        await ocrTask.value
        await ocr.recognitionTaskHandle?.value
        #expect(ocrPresentations == 1)
        #expect(translationPresentations == 0)
        #expect(clipboardDismissals == 1)
        #expect(ocr.text == "Standalone OCR Result")

        // Screenshot translation route.
        feature.present()
        let translateTask = try #require(feature.recognizeImage(imageID, itemIndex: 0))
        await translateTask.value
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while translation.flow.input != "Translated OCR Text" && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(translationPresentations == 1)
        #expect(clipboardDismissals == 2)
        #expect(translation.flow.input == "Translated OCR Text")

        ocr.close()
        translation.close()
        await feature.shutdownAndWait()
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let ptr = try #require(rep.bitmapData)
        memset(ptr, 180, rep.bytesPerRow * height)
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}

private struct LinkageVisionRecognizer: TranslationRecognizing {
    let result: String
    func recognize(_ image: RasterImage) async throws -> String { result }
}

private struct LinkageAIRecognizer: OCRAIRecognizing {
    let result: String
    func recognize(_ request: OCRAIRequest) async throws -> String { result }
}

@MainActor private final class LinkageOCRWriter: TextOutputWriting {
    func copyText(_ text: String) -> CopyOutcome { .copied }
}
