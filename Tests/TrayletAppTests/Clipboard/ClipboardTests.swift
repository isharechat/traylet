import AppKit
import Testing
@testable import TrayletApp

@Suite("Clipboard") @MainActor struct ClipboardTests {
    @Test(arguments: ["shutdown", "resize", "shrink", "clear"])
    func unloadedSessionDoesNotReplaceSavedBodies(action: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-clipboard-reopen-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MemoryClipboardSource()
        let first = ClipboardController(source: source, writer: MemoryClipboardWriter(), archive: V2ClipboardArchive(directory: directory))
        var settings = ClipboardSettings()
        await first.updateSettings(settings); await first.enable()
        for generation in 1...2 {
            source.value = .init(generation: generation, items: [.text("saved \(generation)")], application: "test.app")
            await first.refresh()
        }
        await first.shutdown(); await first.shutdown()
        let secondSource = MemoryClipboardSource()
        let second = ClipboardController(source: secondSource, writer: MemoryClipboardWriter(), archive: V2ClipboardArchive(directory: directory))
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
        let third = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: V2ClipboardArchive(directory: directory))
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
        #expect(try await V2ClipboardArchive(directory: directory).load().map(\.plainText) == ["persist without a setting"])
        let reopened = ClipboardController(source: MemoryClipboardSource(), writer: MemoryClipboardWriter(), archive: V2ClipboardArchive(directory: directory))
        await reopened.enable()
        #expect(reopened.entries.map(\.plainText) == ["persist without a setting"])
        await reopened.shutdown()
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
        source.value = V2ClipboardSnapshot(generation: 5, items: [.text("before enable")], application: "test.app")
        let controller = ClipboardController(source: source, writer: MemoryClipboardWriter())
        #expect(!controller.enabled)
        #expect(source.reads == 0)
        await controller.enable()
        await controller.refresh()
        #expect(controller.entries.isEmpty)
        #expect(source.reads == 0)
        source.value = V2ClipboardSnapshot(generation: 6, items: [.text("after enable")], application: "test.app")
        await controller.refresh()
        #expect(controller.entries.first?.plainText == "after enable")
    }
    @Test func retentionRemovesSavedBodyEvenWithoutNewCopy() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("traylet-clipboard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = V2ClipboardArchive(directory: directory)
        let source = MemoryClipboardSource()
        let clock = ClipboardTestClock()
        let settings = ClipboardSettings()
        let controller = ClipboardController(source: source, writer: MemoryClipboardWriter(), archive: archive, settings: settings, clock: { clock.now })
        await controller.enable()
        source.value = V2ClipboardSnapshot(generation: 1, items: [.text("expire me")], application: "test.app")
        await controller.refresh()
        clock.now.addTimeInterval(8 * 86400)
        await controller.refresh()
        #expect(controller.entries.isEmpty)
        #expect(try await archive.load().isEmpty)
    }

    @Test func expiredCopyDoesNotLeaveSavedBodyAfterNextRefresh() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("traylet-clipboard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = V2ClipboardArchive(directory: directory)
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

}

@MainActor final class MemoryClipboardSource: ClipboardSource {
    var value = V2ClipboardSnapshot(generation: 0, items: [], application: "test.app")
    var reads = 0
    var afterRead: (() -> Void)?
    var generation: Int { value.generation }
    func read(expectedGeneration: Int, excluding: Set<String>) -> V2ClipboardSnapshot? {
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
