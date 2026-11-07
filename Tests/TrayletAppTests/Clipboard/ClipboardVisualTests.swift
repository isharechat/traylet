import AppKit
import SwiftUI
import Testing
@testable import TrayletApp

@Suite("Clipboard Native Evidence") @MainActor struct ClipboardVisualTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAYLET_CLIPBOARD_SNAPSHOT_DIR"] != nil))
    func renderSyntheticListAndPreviewWithoutShowingWindow() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["TRAYLET_CLIPBOARD_SNAPSHOT_DIR"])
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: output, isDirectory: true), withIntermediateDirectories: true)
        let originalLanguage = V2Localization.shared.languageCode
        if let language = ProcessInfo.processInfo.environment["TRAYLET_CLIPBOARD_LANGUAGE"] { V2Localization.shared.languageCode = language }
        defer { V2Localization.shared.languageCode = originalLanguage }
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("traylet-clipboard-visual-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MemoryClipboardSource(); let clock = ClipboardTestClock()
        let feature = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter(), clock: { clock.now })
        await feature.start()
        source.value = .init(generation: 1, items: [.text("合成文字 · 项目备忘\n周五前校对快捷键与翻译设置。此处全部是开发验收生成的合成内容。")], application: "com.example.Notes")
        await feature.controller.refresh()
        if let id = feature.controller.entries.first?.id { await feature.controller.toggleFavorite(id) }
        let image = try syntheticImage()
        var content = ClipboardContent.text("合成图片 · 窗边的山丘\n图片与文字预览，不执行 HTML，也不读取系统剪贴板。")
        content.representations["public.png"] = image
        source.value = .init(generation: 2, items: [content], application: "com.example.Canvas")
        await feature.controller.refresh()
        let imageID = feature.controller.entries.first(where: { $0.imageData != nil })?.id
        #expect(feature.controller.entries.count == 2)
        _ = NSApplication.shared
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark), ("expanded", ColorScheme.light), ("expanded-dark", ColorScheme.dark), ("empty", ColorScheme.light)] {
            if name == "empty" { await feature.controller.deleteAllFavorites(); await feature.controller.clear() }
            else { feature.controller.selectedID = name.hasPrefix("expanded") ? imageID : nil }
            let host = NSHostingView(rootView: ClipboardFeatureView(feature: feature).environment(\.colorScheme, scheme).frame(width: 740, height: 510).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 510), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 740, height: 510)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect((bitmap.colorAt(x: bitmap.pixelsWide - 2, y: bitmap.pixelsHigh - 2)?.alphaComponent ?? 0) > 0.99, "A synthetic window snapshot must include its semantic window backdrop")
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(png.count > 10_000)
            let target = URL(fileURLWithPath: output).appendingPathComponent("traylet-v2-clipboard-\(name).png")
            try png.write(to: target)
            #expect(!window.isVisible)
            window.close()
        }
        await feature.shutdownAndWait()
    }
    private func syntheticImage() throws -> Data {
        let width = 360, height = 220
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.bitmapData)
        for y in 0..<height { for x in 0..<width {
            let offset = y * bitmap.bytesPerRow + x * 3
            let hill = y > 120 + Int(35 * sin(Double(x) / 70))
            bytes[offset] = hill ? 69 : 220; bytes[offset + 1] = hill ? 121 : 235; bytes[offset + 2] = hill ? 97 : 242
            if (x > 30 && x < 38) || (x > 320 && x < 328) || (y > 24 && y < 32) { bytes[offset] = 103; bytes[offset + 1] = 114; bytes[offset + 2] = 121 }
        } }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
