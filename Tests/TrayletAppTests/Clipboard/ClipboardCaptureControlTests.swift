import AppKit
import SwiftUI
import Testing
@testable import TrayletApp

@Suite("Clipboard Capture Controls") @MainActor struct ClipboardCaptureControlTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAYLET_CLIPBOARD_CONTROLS_EVIDENCE_DIR"] != nil))
    func hiddenNativeCaptureControlsRemainReadableInBothLanguagesAndAppearances() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TRAYLET_CLIPBOARD_CONTROLS_EVIDENCE_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let originalLanguage = V2Localization.shared.languageCode, originalAppearance = NSApp.appearance
        let originalGlass = V2AppearanceState.shared.glassEnabled
        defer { V2Localization.shared.languageCode = originalLanguage; NSApp.appearance = originalAppearance; V2AppearanceState.shared.glassEnabled = originalGlass }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-capture-control-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MemoryClipboardSource()
        let feature = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter())
        defer { feature.shutdown() }
        await feature.start(poll: false)
        source.value = .init(generation: 1, items: [.text("Synthetic clipboard sample")], application: "synthetic.app")
        await feature.controller.refresh()
        var settings = feature.controller.settings; settings.captureText = false
        await feature.controller.updateSettings(settings)
        feature.controller.setIgnoringNextCopy(true)
        V2AppearanceState.shared.glassEnabled = false
        for dark in [false, true] {
            V2Localization.shared.languageCode = dark ? "en" : "zh-Hans"
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let suffix = dark ? "dark-en" : "light-zh"
            try await capture(ClipboardFeatureView(feature: feature), size: NSSize(width: 300, height: 320), dark: dark, to: output.appendingPathComponent("ignore-armed-\(suffix).png"))
            try await capture(ClipboardFeatureSettingsView(feature: feature), size: NSSize(width: 540, height: 720), dark: dark, to: output.appendingPathComponent("record-types-\(suffix).png"))
        }
        settings.captureImages = false
        await feature.controller.updateSettings(settings)
        try await capture(ClipboardFeatureSettingsView(feature: feature), size: NSSize(width: 540, height: 720), dark: true, to: output.appendingPathComponent("record-types-none-dark-en.png"))
        #expect(feature.controller.ignoringNextCopy && feature.controller.enabled)
        #expect(source.reads == 1)
        await feature.shutdownAndWait()
    }
    private func capture<Content: View>(_ content: Content, size: NSSize, dark: Bool, to destination: URL) async throws {
        let host = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = host
        defer { window.close() }
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 3000 && !window.isVisible)
        try png.write(to: destination)
    }
    @Test func privateBoardRoundTripPreservesFormatsAndSeparatesSelfCopyFromIgnoredExternalCopy() async throws {
        let name = NSPasteboard.Name("local.traylet.capture-roundtrip." + UUID().uuidString)
        let board = NSPasteboard(name: name); board.clearContents()
        defer { board.releaseGlobally() }
        let native = V2ClipboardNativeWriter(privatePasteboardName: name)
        let controller = ClipboardController(source: V2ClipboardNativeSource(privatePasteboardName: name, application: { "synthetic.app" }), writer: native)
        await controller.enable()
        var text = ClipboardContent.text("Synthetic rich text")
        text.representations["public.html"] = Data("<b>Synthetic rich text</b>".utf8)
        #expect(native.write([text], marker: "external") == .copied(generation: board.changeCount))
        await controller.refresh()
        let original = try #require(controller.entries.first)
        controller.setIgnoringNextCopy(true)
        #expect(controller.copy(original.id))
        await controller.refresh()
        #expect(controller.ignoringNextCopy && controller.entries == [original])
        let image = ClipboardContent(representations: ["public.png": try EditingTests.fixture().pngData, ClipboardContent.textType: Data("Synthetic image caption".utf8)])
        #expect(native.write([image], marker: "external") == .copied(generation: board.changeCount))
        await controller.refresh()
        #expect(!controller.ignoringNextCopy && controller.entries == [original])
        var settings = controller.settings; settings.captureText = false
        await controller.updateSettings(settings)
        #expect(native.write([image], marker: "external") == .copied(generation: board.changeCount))
        await controller.refresh()
        #expect(controller.entries.first?.items == [image])
        let kept = controller.entries
        settings.captureImages = false
        await controller.updateSettings(settings)
        #expect(native.write([.text("disabled")], marker: "external") == .copied(generation: board.changeCount))
        await controller.refresh()
        #expect(controller.entries == kept)
        settings.captureText = true
        await controller.updateSettings(settings)
        #expect(native.write([text], marker: "external") == .copied(generation: board.changeCount))
        await controller.refresh()
        #expect(controller.entries.first?.items == [text] && controller.entries.first?.id == original.id)
        controller.stop()
    }
    @Test func changingCaptureTypesDoesNotBackfillTheCurrentBoardOrConsumeAnArmedIgnore() async throws {
        let source = MemoryClipboardSource()
        let controller = ClipboardController(source: source, writer: MemoryClipboardWriter())
        await controller.enable()
        var settings = controller.settings; settings.captureText = false; settings.captureImages = false
        await controller.updateSettings(settings)
        source.value = .init(generation: 1, items: [.text("before type enabled")], application: "synthetic.app")
        settings.captureText = true
        await controller.updateSettings(settings); await controller.refresh()
        #expect(controller.entries.isEmpty && source.reads == 0)
        controller.setIgnoringNextCopy(true)
        settings.captureImages = true
        await controller.updateSettings(settings)
        #expect(controller.ignoringNextCopy)
        source.value = .init(generation: 2, items: [.text("ignored after type change")], application: "synthetic.app")
        await controller.refresh()
        #expect(!controller.ignoringNextCopy && controller.entries.isEmpty && source.reads == 0)
    }
    @Test func existingPreferencesKeepExplicitChoicesAndNewTypesRoundTripWithoutEnablingRecording() async throws {
        let old = Data(#"{"maximumCount":23,"retentionDays":4,"saveLocally":true,"excludedApplications":["excluded.app"]}"#.utf8)
        var settings = try JSONDecoder().decode(ClipboardSettings.self, from: old)
        #expect(settings.maximumCount == 23 && settings.retentionDays == 4 && settings.saveLocally)
        #expect(settings.excludedApplications == ["excluded.app"] && settings.captureText && settings.captureImages)
        settings.captureText = false; settings.captureImages = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-capture-types-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = V2ClipboardArchive(directory: directory)
        try await archive.saveSettings(settings)
        let source = MemoryClipboardSource()
        let reopened = ClipboardController(source: source, writer: MemoryClipboardWriter(), archive: archive)
        await reopened.loadPreferences()
        #expect(reopened.settings == settings)
        #expect(!reopened.enabled && !reopened.ignoringNextCopy && source.reads == 0)
        await reopened.shutdown()
    }
    @Test func nativeMixedCopyIsRejectedBeforeAnyDelayedRepresentationIsRequested() throws {
        let name = NSPasteboard.Name("local.traylet.capture-control." + UUID().uuidString)
        let board = NSPasteboard(name: name)
        defer { board.releaseGlobally() }
        let delayed = DelayedCaptureText()
        let text = NSPasteboardItem()
        try #require(text.setDataProvider(delayed, forTypes: [.string]))
        let image = NSPasteboardItem()
        try #require(image.setData(try EditingTests.fixture().pngData, forType: .png))
        board.clearContents(); try #require(board.writeObjects([text, image]), "Private board unavailable; never use general as fallback")
        let source: any ClipboardSource = V2ClipboardNativeSource(privatePasteboardName: name, application: { "synthetic.app" })
        #expect(delayed.requests == 0)
        let result = source.read(expectedGeneration: board.changeCount, excluding: [], policy: .init(text: true, images: false))
        #expect(result == nil)
        #expect(delayed.requests == 0)
    }
    @Test func recordingTypesAffectNewCopiesAndKeepPreviouslyRecordedEntriesAndFormats() async throws {
        let source = MemoryClipboardSource()
        let controller = ClipboardController(source: source, writer: MemoryClipboardWriter())
        await controller.enable()
        source.value = .init(generation: 1, items: [.text("keep prior")], application: "synthetic.app")
        await controller.refresh()
        let prior = try #require(controller.entries.first)
        var settings = controller.settings; settings.captureText = false
        await controller.updateSettings(settings)
        source.value = .init(generation: 2, items: [.text("disabled text")], application: "synthetic.app")
        await controller.refresh()
        #expect(controller.entries == [prior])
        let pixels = try EditingTests.fixture().pngData
        let image = ClipboardContent(representations: ["public.png": pixels, ClipboardContent.textType: Data("image caption".utf8)])
        source.value = .init(generation: 3, items: [image], application: "synthetic.app")
        await controller.refresh()
        #expect(controller.entries.first?.items == [image])
        #expect(controller.entries.last == prior)
        let kept = controller.entries
        source.value = .init(generation: 4, items: [.text("mixed text"), image], application: "synthetic.app")
        await controller.refresh()
        #expect(controller.entries == kept) // A mixed copy is never saved as a partial reconstruction.
    }
    @Test(arguments: ["sensitive", "excluded", "unsupported"])
    func ignoredExternalChangesConsumeTheExclusionWithoutReadingBodies(_ kind: String) async {
        let source = MemoryClipboardSource()
        var settings = ClipboardSettings(); settings.excludedApplications = ["excluded.app"]
        let controller = ClipboardController(source: source, writer: MemoryClipboardWriter(), settings: settings)
        await controller.enable(); controller.setIgnoringNextCopy(true)
        source.value = .init(generation: 1, items: kind == "unsupported" ? [] : [.text("synthetic")], application: kind == "excluded" ? "excluded.app" : "synthetic.app", sensitive: kind == "sensitive")
        await controller.refresh()
        #expect(!controller.ignoringNextCopy && controller.entries.isEmpty && source.reads == 0)
        source.value = .init(generation: 2, items: [.text("next ordinary")], application: "synthetic.app")
        await controller.refresh()
        #expect(controller.entries.first?.plainText == "next ordinary")
    }
    @Test(arguments: [false, true]) func selfCopiesDoNotConsumeTheNextExternalExclusion(skipSelfObservation: Bool) async throws {
        let source = MemoryClipboardSource(), writer = MemoryClipboardWriter()
        let controller = ClipboardController(source: source, writer: writer)
        await controller.enable()
        source.value = .init(generation: 1, items: [.text("original")], application: "synthetic.app")
        await controller.refresh()
        let original = try #require(controller.entries.first)
        controller.setIgnoringNextCopy(true)
        #expect(controller.copy(original.id))
        source.value = .init(generation: 10, items: writer.writes[0], application: "synthetic.app", marker: writer.markers[0])
        if !skipSelfObservation { await controller.refresh() }
        #expect(controller.ignoringNextCopy && source.reads == 1)
        source.value = .init(generation: 11, items: [.text("external")], application: "synthetic.app")
        await controller.refresh()
        #expect(!controller.ignoringNextCopy && source.reads == 1 && controller.entries == [original])
        source.value = .init(generation: 12, items: [.text("after external exclusion")], application: "synthetic.app")
        await controller.refresh()
        #expect(source.reads == 2 && controller.entries.first?.plainText == "after external exclusion")
    }
    @Test func pauseResumePreservesTheExclusionButStopDoesNot() async {
        let source = MemoryClipboardSource()
        let controller = ClipboardController(source: source, writer: MemoryClipboardWriter())
        controller.setIgnoringNextCopy(true)
        #expect(!controller.ignoringNextCopy && !controller.enabled && source.reads == 0)
        await controller.enable(); controller.setIgnoringNextCopy(true); controller.pause()
        source.value = .init(generation: 1, items: [.text("while paused")], application: "synthetic.app")
        await controller.refresh(); controller.resume(); await controller.refresh()
        #expect(controller.ignoringNextCopy && source.reads == 0)
        source.value = .init(generation: 2, items: [.text("after resume")], application: "synthetic.app")
        await controller.refresh()
        #expect(!controller.ignoringNextCopy && controller.entries.isEmpty && source.reads == 0)
        controller.setIgnoringNextCopy(true); controller.stop()
        #expect(!controller.ignoringNextCopy && !controller.enabled)
    }
    @Test func cancellingAnArmedIgnoreDoesNotBackfillAnUnobservedCopy() async {
        let source = MemoryClipboardSource()
        let controller = ClipboardController(source: source, writer: MemoryClipboardWriter())
        await controller.enable()
        controller.setIgnoringNextCopy(true)
        source.value = .init(generation: 1, items: [.text("before cancel")], application: "synthetic.app")
        controller.setIgnoringNextCopy(false)
        await controller.refresh()
        #expect(controller.entries.isEmpty && source.reads == 0)
        source.value = .init(generation: 2, items: [.text("after cancel")], application: "synthetic.app")
        await controller.refresh()
        #expect(controller.entries.compactMap(\.plainText) == ["after cancel"])
    }
    @Test func nextExternalChangeIsSkippedBeforeReadingItsBodyThenNormalRecordingResumes() async {
        let source = MemoryClipboardSource()
        let controller = ClipboardController(source: source, writer: MemoryClipboardWriter())
        await controller.enable()
        controller.setIgnoringNextCopy(true)
        source.value = .init(generation: 1, items: [.text("ignored synthetic")], application: "synthetic.app")
        await controller.refresh()
        #expect(controller.entries.isEmpty && !controller.ignoringNextCopy)
        #expect(source.reads == 0)
        source.value = .init(generation: 2, items: [.text("next synthetic")], application: "synthetic.app")
        await controller.refresh()
        #expect(controller.entries.compactMap(\.plainText) == ["next synthetic"])
        #expect(source.reads == 1)
    }
}

private final class DelayedCaptureText: NSObject, NSPasteboardItemDataProvider {
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.withLock { count } }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        lock.withLock { count += 1 }
        item.setString("Synthetic delayed content", forType: type)
    }
}
