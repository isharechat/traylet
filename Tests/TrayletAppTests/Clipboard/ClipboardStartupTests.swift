import Foundation
import Testing
@testable import TrayletApp

@Suite("Clipboard Startup") @MainActor struct ClipboardStartupTests {
    @Test func explicitConfirmationLoadsPreferencesAndPollsWithoutOpeningAView() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-clipboard-start-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = V2ClipboardArchive(directory: directory)
        var settings = ClipboardSettings(); settings.maximumCount = 12; settings.retentionDays = 3
        settings.excludedApplications = ["excluded.app"]
        try await archive.saveSettings(settings)
        let source = MemoryClipboardSource()
        source.value = .init(generation: 4, items: [.text("before launch")], application: "test.app")
        let feature = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter())
        feature.requestRecording()
        await feature.confirmRecording()?.value
        #expect(feature.controller.enabled && feature.controller.settings == settings)
        await feature.controller.refresh()
        #expect(source.reads == 0 && feature.controller.entries.isEmpty)
        source.value = .init(generation: 5, items: [.text("after launch")], application: "test.app")
        feature.requestRecording()
        await feature.confirmRecording()?.value // Repeated confirmation must not reset the baseline or create another collector.
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while feature.controller.entries.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(feature.controller.entries.map(\.plainText) == ["after launch"])
        source.value = .init(generation: 6, items: [.text("excluded")], application: "excluded.app")
        await feature.controller.refresh()
        #expect(feature.controller.entries.count == 1)
        await feature.shutdownAndWait()
        #expect(!feature.controller.enabled && feature.controller.entries.isEmpty)
        #expect(try await archive.load().isEmpty)
    }

    @Test func startupRestoresOnlyOptedInHistoryAndPrunesExpiredItems() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-clipboard-restore-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = V2ClipboardArchive(directory: directory)
        var settings = ClipboardSettings(); settings.saveLocally = true; settings.retentionDays = 1
        try await archive.saveSettings(settings)
        let now = Date()
        let entries = [0.0, -172800.0].map { offset in
            let items: [ClipboardContent] = [.text(offset == 0 ? "recent" : "expired")]
            return ClipboardEntry(id: UUID(), digest: ClipboardPolicy.digest(items), items: items, capturedAt: now.addingTimeInterval(offset), favorite: false, application: "test.app")
        }
        try await archive.replace(entries, revision: 1)
        let source = MemoryClipboardSource()
        let feature = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter(), clock: { now })
        await feature.start(poll: false)
        #expect(feature.controller.entries.map(\.plainText) == ["recent"])
        #expect(source.reads == 0)
        await feature.shutdownAndWait()
        #expect(try await archive.load().map(\.plainText) == ["recent"])
    }

    @Test func shutdownRejectsQueuedAndLaterStartup() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-clipboard-stop-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MemoryClipboardSource()
        let feature = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter())
        let queued = Task { await feature.start() }
        await feature.shutdownAndWait()
        await queued.value
        await feature.start()
        source.value = .init(generation: 1, items: [.text("after exit")], application: "test.app")
        await feature.controller.refresh()
        #expect(!feature.controller.enabled && feature.controller.entries.isEmpty && source.reads == 0)
    }
}
