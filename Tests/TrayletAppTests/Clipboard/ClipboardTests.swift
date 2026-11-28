import AppKit
import Testing
@testable import TrayletApp

@Suite("Clipboard") @MainActor struct ClipboardTests {
    @Test(arguments: ["shutdown", "resize", "shrink", "clear"])
    func unloadedSessionDoesNotReplaceSavedBodies(action: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-clipboard-reopen-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MemoryClipboardSource()
        let first = ClipboardController(source: source, writer: MemoryClipboardWriter(), archive: ClipboardArchive(directory: directory))
        var settings = ClipboardSettings()
        await first.updateSettings(settings); await first.enable()
        for generation in 1...2 {
            source.value = .init(generation: generation, items: [.text("saved \(generation)")], application: "test.app")
            await first.refresh()
        }
        await first.shutdown(); await first.shutdown()
        let secondSource = MemoryClipboardSource()
        let second = ClipboardController(source: secondSource, writer: MemoryClipboardWriter(), archive: ClipboardArchive(directory: directory))
        await second.loadPreferences()
        #expect(!second.enabled && second.entries.isEmpty)
        switch action {
        case "resize": settings.maximumCount = 20; await second.updateSettings(settings)
        case "shrink": settings.maximumCount = 1; await second.updateSettings(settings)
        case "clear": await second.clear()
        default: break
        }
        await second.shutdown()
        #expect(secondSource.reads == 0)
        let third = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: ClipboardArchive(directory: directory))
        await third.loadPreferences(); await third.enable()
        let expected = action == "clear" ? [] : action == "shrink" ? ["saved 2"] : ["saved 2", "saved 1"]
        #expect(third.entries.compactMap(\.plainText) == expected)
        await third.shutdown()
    }
    @Test func historyIsPersistedWithoutASettingAndDetailFollowsSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-clipboard-detail-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MemoryClipboardSource()
        let feature = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter())
        await feature.start(poll: false)
        #expect(!feature.showsDetail)
        source.value = .init(generation: 1, items: [.text("persist without a setting")], application: "test.app")
        await feature.controller.refresh()
        let id = try #require(feature.controller.entries.first?.id)
        #expect(!feature.showsDetail)
        feature.controller.selectedID = id
        #expect(feature.showsDetail)
        await feature.shutdownAndWait()
        #expect(try await ClipboardArchive(directory: directory).load().map(\.plainText) == ["persist without a setting"])
        let reopened = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: ClipboardArchive(directory: directory))
        await reopened.enable()
        #expect(reopened.entries.map(\.plainText) == ["persist without a setting"])
        await reopened.shutdown()
    }
    @Test func detailPaneUpdatesSynchronouslyForEachSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-clipboard-detail-stale-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let source = MemoryClipboardSource()
        let feature = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter(),
                                       presentWindow: { _ in }, dismissWindow: { _ in })
        await feature.start(poll: false)
        for (generation, text) in ["first", "second"].enumerated() {
            source.value = .init(generation: generation + 1, items: [.text(text)], application: "test.app")
            await feature.controller.refresh()
        }
        let first = try #require(feature.controller.entries.last?.id)
        let second = try #require(feature.controller.entries.first?.id)
        feature.present()
        let mainPanel = try #require(feature.mainPanelForTesting)
        #expect(mainPanel.frame.size == NSSize(width: ClipboardFeature.windowWidth, height: ClipboardFeature.windowHeight))
        #expect(!feature.showsDetail)
        #expect(feature.renderedDetailID == nil)
        feature.controller.selectedID = first
        try await Task.sleep(for: .milliseconds(20))
        #expect(feature.showsDetail)
        #expect(feature.renderedDetailID == first)
        feature.controller.selectedID = second
        try await Task.sleep(for: .milliseconds(20))
        // The single-window detail pane re-renders synchronously for the new selection instead of showing the previous entry.
        #expect(feature.renderedDetailID == second)
        feature.controller.selectedID = nil
        try await Task.sleep(for: .milliseconds(20))
        #expect(!feature.showsDetail)
        #expect(feature.renderedDetailID == nil)
        await feature.shutdownAndWait()
    }
    @Test(arguments: ["system", "/tmp", "/private/tmp"])
    func freshSystemTemporaryDirectoryHasNoPreferencesError(location: String) async throws {
        let root = location == "system" ? FileManager.default.temporaryDirectory : URL(fileURLWithPath: location)
        let directory = root.appendingPathComponent("traylet-clipboard-fresh-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let source = MemoryClipboardSource()
        let feature = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter())
        await feature.controller.loadPreferences()
        #expect(feature.controller.message == nil)
        #expect(!feature.controller.enabled && feature.controller.entries.isEmpty)
        #expect(source.reads == 0)
        await feature.shutdownAndWait()
    }
    @Test func constructionDoesNotCaptureAndStartupDoesNotBackfill() async {
        let source = MemoryClipboardSource()
        source.value = ClipboardSnapshot(generation: 5, items: [.text("before enable")], application: "test.app")
        let controller = ClipboardController(source: source, writer: MemoryClipboardWriter())
        #expect(!controller.enabled)
        #expect(source.reads == 0)
        await controller.enable()
        await controller.refresh()
        #expect(controller.entries.isEmpty)
        #expect(source.reads == 0)
        source.value = ClipboardSnapshot(generation: 6, items: [.text("after enable")], application: "test.app")
        await controller.refresh()
        #expect(controller.entries.first?.plainText == "after enable")
    }
    @Test func retentionRemovesSavedBodyEvenWithoutNewCopy() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("traylet-clipboard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = ClipboardArchive(directory: directory)
        let source = MemoryClipboardSource()
        let clock = ClipboardTestClock()
        let settings = ClipboardSettings()
        let controller = ClipboardController(source: source, writer: MemoryClipboardWriter(), archive: archive, settings: settings, clock: { clock.now })
        await controller.enable()
        source.value = ClipboardSnapshot(generation: 1, items: [.text("expire me")], application: "test.app")
        await controller.refresh()
        clock.now.addTimeInterval(8 * 86400)
        await controller.refresh()
        #expect(controller.entries.isEmpty)
        #expect(try await archive.load().isEmpty)
    }

    @Test func expiredCopyDoesNotLeaveSavedBodyAfterNextRefresh() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("traylet-clipboard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = ClipboardArchive(directory: directory)
        let source = MemoryClipboardSource(); let writer = MemoryClipboardWriter(); let clock = ClipboardTestClock()
        let settings = ClipboardSettings()
        let controller = ClipboardController(source: source, writer: writer, archive: archive, settings: settings, clock: { clock.now })
        await controller.enable()
        source.value = .init(generation: 1, items: [.text("expire before copy")], application: "test.app")
        await controller.refresh()
        let id = try #require(controller.entries.first?.id)
        clock.now.addTimeInterval(8 * 86400)
        controller.copy(id)
        #expect(writer.writes.isEmpty)
        await controller.refresh()
        #expect(try await archive.load().isEmpty)
    }

    @Test func displaySingleLineTreatsCJKAsWrappableAndURLsAndBlobsAsSingleLine() {
        func display(_ text: String) -> ClipboardDisplay {
            ClipboardDisplay(ClipboardEntry(id: UUID(), digest: "display-" + text, items: [.text(text)], capturedAt: Date(), favorite: false, application: "test.app"))
        }
        // Chinese text has no spaces but must wrap by column width, not become one scrollable line.
        let cjk = String(repeating: "这是一个较长的中文段落用于验证换行判定。", count: 6)
        #expect(!display(cjk).singleLine)
        // A standalone URL stays one scrollable line even when short.
        #expect(display("https://example.com/" + String(repeating: "a", count: 120)).singleLine)
        #expect(display("https://example.com/path").kind == .link)
        // A long ASCII blob with no break points is one scrollable line.
        #expect(display(String(repeating: "abc123", count: 40)).singleLine)
        // Ordinary prose with spaces wraps normally.
        let prose = Array(repeating: "the quick brown fox", count: 20).joined(separator: " ")
        #expect(!display(prose).singleLine)
    }

    @Test func mainWindowMatchesMasterDetailStyleAndCloseAction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-clipboard-master-detail-style-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        var dismissals = 0
        let source = MemoryClipboardSource()
        let feature = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter(),
                                       presentWindow: { _ in }, dismissWindow: { _ in dismissals += 1 })
        await feature.start(poll: false)
        source.value = .init(generation: 1, items: [.text("detail sample")], application: "test.app")
        await feature.controller.refresh()
        feature.present()
        #expect(feature.isWindowFocused)
        let mainPanel = try #require(feature.mainPanelForTesting)
        #expect(mainPanel.styleMask.contains(.titled))
        #expect(mainPanel.styleMask.contains(.closable))
        #expect(mainPanel.styleMask.contains(.resizable))
        #expect(mainPanel.styleMask.contains(.fullSizeContentView))
        #expect(mainPanel.titleVisibility == .hidden)
        #expect(mainPanel.titlebarAppearsTransparent)
        #expect(mainPanel.title == L("剪贴板"))
        #expect(mainPanel.minSize == NSSize(width: ClipboardFeature.minimumWidth, height: ClipboardFeature.minimumHeight))
        mainPanel.close()
        #expect(dismissals == 1)
        #expect(!feature.isWindowFocused)
        await feature.shutdownAndWait()
    }

    @Test func mainWindowMatchesMasterDetailSizeInitiallyAndOnResize() async throws {
        #expect(ClipboardFeature.windowWidth == 840)
        #expect(ClipboardFeature.windowHeight == 540)
        #expect(ClipboardFeature.minimumWidth == 620)
        #expect(ClipboardFeature.minimumHeight == 400)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-clipboard-master-detail-size-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        var capturedMainPanel: NSPanel?
        let source = MemoryClipboardSource()
        let feature = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter(),
                                       presentWindow: { capturedMainPanel = $0 }, dismissWindow: { _ in })
        await feature.start(poll: false)
        source.value = .init(generation: 1, items: [.text("detail size sample")], application: "test.app")
        await feature.controller.refresh()
        let id = try #require(feature.controller.entries.first?.id)
        feature.present()
        let mainPanel = try #require(capturedMainPanel)
        #expect(mainPanel.frame.size == NSSize(width: 840, height: 540))
        feature.controller.selectedID = id
        try await Task.sleep(for: .milliseconds(20))
        #expect(feature.showsDetail)
        #expect(mainPanel.frame.size == NSSize(width: 840, height: 540))
        mainPanel.setFrame(NSRect(origin: mainPanel.frame.origin, size: NSSize(width: 960, height: 620)), display: false)
        #expect(mainPanel.frame.size == NSSize(width: 960, height: 620))
        mainPanel.setFrame(NSRect(origin: mainPanel.frame.origin, size: NSSize(width: 620, height: 400)), display: false)
        #expect(mainPanel.frame.size == NSSize(width: 620, height: 400))
        await feature.shutdownAndWait()
    }

    @Test func clipboardStorageCopyRemovesEncryptionWording() {
        #expect(English.strings["历史始终保存在本机"] == "History is always saved locally")
        #expect(English.strings["按设置的数量与期限清理。"] == "Pruned by the configured count and retention period.")
        let allowedEncryptedCredentialCopy: Set<String> = [
            "本机加密保存",
            "将保留当前 v2 配置文件的独立备份，恢复系统翻译默认值，并清除本机加密保存的 API Key。不会读取或修改旧版本配置或其他数据。",
            "将保留当前 v2 配置文件的独立备份，恢复默认 OCR 设置，并清除本机加密保存的 OCR API Key。"
        ]
        for (source, translation) in English.strings where !allowedEncryptedCredentialCopy.contains(source) {
            #expect(!source.contains("加密"))
            #expect(!translation.localizedCaseInsensitiveContains("encrypt"))
        }
    }

}

@MainActor final class MemoryClipboardSource: ClipboardSource {
    var value = ClipboardSnapshot(generation: 0, items: [], application: "test.app")
    var reads = 0
    var afterRead: (() -> Void)?
    var generation: Int { value.generation }
    func read(expectedGeneration: Int, excluding: Set<String>) -> ClipboardSnapshot? {
        reads += 1
        let snapshot = value
        afterRead?()
        return snapshot.generation == expectedGeneration && !excluding.contains(value.application) ? snapshot : nil
    }
}
@MainActor final class MemoryClipboardWriter: ClipboardWriting {
    var writes: [[ClipboardContent]] = []
    var markers: [String] = []
    var result = ClipboardWriteResult.copied(generation: 10)
    func write(_ items: [ClipboardContent], marker: String) -> ClipboardWriteResult { writes.append(items); markers.append(marker); return result }
}

@MainActor final class ClipboardTestClock { var now = Date(timeIntervalSince1970: 1_000_000) }
