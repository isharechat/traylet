import AppKit
import Foundation
import Testing
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
