import AppKit
import SwiftUI
import Testing
@testable import TrayletApp

@Suite("Clipboard Image Native Evidence") @MainActor struct ClipboardImageEvidenceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAYLET_CLIPBOARD_SNAPSHOT_DIR"] != nil))
    func renderImageActionsOrderingAndPendingStatesWithoutShowingWindows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-image-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let language = V2Localization.shared.languageCode
        defer { V2Localization.shared.languageCode = language }
        let data = try EditingTests.fixture().pngData
        let prepared = try await ClipboardImageDecoder.prepare(data)
        let gate = EvidenceImageGate()
        let source = MemoryClipboardSource(), editing = ClipboardImageEditing(prepare: { _ in await gate.wait() })
        let feature = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter(), imageEditing: editing)
        defer { feature.shutdown() }
        await feature.start(poll: false)
        source.value = .init(generation: 1, items: [.text("合成收藏 · 手动顺序")], application: "synthetic.notes")
        await feature.controller.refresh()
        await feature.controller.toggleFavorite(try #require(feature.controller.entries.first?.id))
        source.value = .init(generation: 2, items: [.text("合成图片 · 原始 PNG 与文字保留"), .init(representations: ["public.png": data])], application: "synthetic.canvas")
        await feature.controller.refresh()
        let imageID = try #require(feature.controller.entries.first(where: { $0.imageData != nil })?.id)
        feature.controller.selectedID = imageID
        feature.setDetailExpanded(true)
        for dark in [false, true] {
            V2Localization.shared.languageCode = "zh-Hans"
            try await render(feature, name: "image-actions-\(dark ? "dark" : "light")", width: 700, height: 460, dark: dark)
        }
        V2Localization.shared.languageCode = "en"
        try await render(feature, name: "image-actions-en", width: 580, height: 400, dark: false)
        V2Localization.shared.languageCode = "zh-Hans"
        feature.setDetailExpanded(false)
        feature.canEditImage = { true }; feature.onEditImage = { _ in false }
        let work = try #require(feature.editImage(imageID, itemIndex: 1))
        await gate.waitUntilPending()
        try await render(feature, name: "image-preparing-compact", width: 300, height: 320, dark: false)
        feature.imageEditing.cancel()
        await gate.finish(prepared); await work.value
        feature.canEditImage = { false }
        #expect(feature.editImage(imageID, itemIndex: 1) == nil)
        try await render(feature, name: "image-busy-compact-dark", width: 300, height: 320, dark: true)
        #expect(!feature.imageEditing.isPreparing)
        await feature.shutdownAndWait()
    }
    private func render(_ feature: ClipboardFeature, name: String, width: CGFloat, height: CGFloat, dark: Bool) async throws {
        let output = try #require(ProcessInfo.processInfo.environment["TRAYLET_CLIPBOARD_SNAPSHOT_DIR"])
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: ClipboardFeatureView(feature: feature).environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 4000 && !window.isVisible)
        try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }
}
private actor EvidenceImageGate {
    private var continuation: CheckedContinuation<ClipboardPreparedImage, Never>?
    func wait() async -> ClipboardPreparedImage { await withCheckedContinuation { continuation = $0 } }
    func waitUntilPending() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if continuation != nil { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Evidence preparation did not reach gate")
    }
    func finish(_ image: ClipboardPreparedImage) { continuation?.resume(returning: image); continuation = nil }
}
