import AppKit
import SwiftUI
import Testing
@testable import TrayletApp

@Suite("Clipboard Consent") @MainActor struct ClipboardConsentTests {
    @Test func confirmedActionSurvivesTheAlertsAutomaticDismissal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-consent-dismissal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MemoryClipboardSource()
        source.value = .init(generation: 7, items: [.text("before confirmation")], application: "test.app")
        let feature = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter())
        feature.requestRecording()
        // SwiftUI can clear presentation before invoking the chosen button action.
        feature.recordingConfirmationBinding.wrappedValue = false
        await feature.confirmRecording(poll: false)?.value
        #expect(feature.controller.enabled)
        #expect(!feature.recordingConfirmationPresented && !feature.recordingStarting)
        await feature.controller.refresh()
        #expect(source.reads == 0 && feature.controller.entries.isEmpty)
        source.value = .init(generation: 8, items: [.text("after confirmation")], application: "test.app")
        await feature.controller.refresh()
        #expect(feature.controller.entries.map(\.plainText) == ["after confirmation"])
        await feature.shutdownAndWait()
    }
    @Test func confirmationIsConsumedSynchronouslyAndOnlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-consent-once-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MemoryClipboardSource()
        let feature = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter())
        // Presentation writes cannot manufacture consent.
        feature.recordingConfirmationBinding.wrappedValue = true
        #expect(feature.confirmRecording(poll: false) == nil)
        feature.requestRecording()
        let accepted = try #require(feature.confirmRecording(poll: false))
        #expect(feature.recordingStarting && !feature.recordingConfirmationPresented)
        feature.recordingConfirmationBinding.wrappedValue = false
        #expect(feature.confirmRecording(poll: false) == nil)
        await accepted.value
        #expect(feature.controller.enabled && !feature.recordingStarting && source.reads == 0)
        await feature.shutdownAndWait()
    }
    @Test(arguments: ["cancel", "escape", "close", "shutdown"])
    func cancellationInvalidatesTheChoiceEvenAfterPresentationHides(_ route: String) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-consent-cancel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MemoryClipboardSource()
        var panel: NSPanel?
        let feature = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter(), presentWindow: { panel = $0 })
        if route == "close" { feature.present() }
        feature.requestRecording()
        feature.recordingConfirmationBinding.wrappedValue = false
        switch route {
        case "cancel": feature.cancelRecording()
        case "escape": feature.dismiss()
        case "close": try #require(panel).close()
        default: await feature.shutdownAndWait()
        }
        #expect(feature.confirmRecording(poll: false) == nil)
        #expect(!feature.controller.enabled && !feature.recordingStarting && source.reads == 0)
        #expect(panel?.isVisible != true)
        await feature.shutdownAndWait()
    }
    @Test func closingAfterConfirmationCancelsQueuedStartupAndAllowsAFreshChoice() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-consent-queued-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MemoryClipboardSource()
        let feature = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter())
        feature.requestRecording()
        let canceled = try #require(feature.confirmRecording(poll: false))
        feature.dismiss()
        await canceled.value
        #expect(!feature.controller.enabled && source.reads == 0)
        feature.requestRecording()
        let accepted = try #require(feature.confirmRecording(poll: false))
        await accepted.value
        #expect(feature.controller.enabled && !feature.recordingStarting && source.reads == 0)
        feature.dismiss()
        #expect(feature.controller.enabled) // Navigation never undoes an already active explicit choice.
        await feature.shutdownAndWait()
    }
    @Test func nativeEscapeFromHiddenSearchWithdrawsPendingConsent() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-consent-native-escape-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MemoryClipboardSource()
        var nativePanel: NSPanel?
        let feature = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter(), presentWindow: { nativePanel = $0 })
        feature.present()
        try await Task.sleep(for: .milliseconds(80))
        let panel = try #require(nativePanel)
        let editor = try #require(panel.firstResponder as? NSTextView)
        feature.requestRecording()
        feature.recordingConfirmationBinding.wrappedValue = false
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
                                                  charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        editor.keyDown(with: escape)
        #expect(feature.confirmRecording(poll: false) == nil)
        #expect(!feature.controller.enabled && source.reads == 0 && !panel.isVisible)
        await feature.shutdownAndWait()
    }
    @Test func cancelDuringPreferenceLoadingCannotStartOrClearANewerConfirmation() async throws {
        let source = ConsentObservedSource(), archive = ConsentSuspendedArchive()
        let feature = ClipboardFeature(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                       source: source, writer: MemoryClipboardWriter(), archive: archive)
        defer { feature.shutdown(); Task { await archive.releaseAll() } }
        let preferencesEntered = await waitUntil { await archive.preferencesEntered }
        try #require(preferencesEntered)
        feature.requestRecording()
        let canceled = try #require(feature.confirmRecording(poll: false))
        await Task.yield() // Let the original confirmation reach the real preferences await.
        feature.dismiss()
        #expect(!feature.controller.enabled && source.baselineReads == 0 && source.bodyReads == 0)
        feature.requestRecording()
        let accepted = try #require(feature.confirmRecording(poll: false))
        await archive.releasePreferences()
        await canceled.value
        let favoritesEntered = await waitUntil { await archive.favoritesEntered }
        try #require(favoritesEntered)
        #expect(feature.controller.enabled && feature.recordingStarting)
        #expect(source.baselineReads == 1 && source.bodyReads == 0)
        await archive.releaseFavorites()
        await accepted.value
        #expect(feature.controller.enabled && !feature.recordingStarting)
        #expect(source.baselineReads == 1 && source.bodyReads == 0)
        await feature.shutdownAndWait()
    }
    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return await condition()
    }
    @Test func revisitingSettingsPreservesQuerySelectionAndPausedRecording() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-clipboard-settings-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MemoryClipboardSource()
        let feature = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter())
        defer { feature.shutdown() }
        feature.requestRecording(); await feature.confirmRecording(poll: false)?.value
        for (index, text) in ["alpha", "alpine"].enumerated() {
            source.value = .init(generation: index + 1, items: [.text(text)], application: "test.app")
            await feature.controller.refresh()
        }
        let selected = try #require(feature.controller.entries.last?.id)
        feature.controller.query = "alp"; feature.controller.selectedID = selected
        feature.controller.pause()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for _ in 0..<2 {
            window.contentView = NSHostingView(rootView: ClipboardFeatureSettingsView(feature: feature))
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            window.contentView = NSView()
        }
        #expect(feature.controller.enabled && feature.controller.paused)
        #expect(feature.controller.query == "alp" && feature.controller.selectedID == selected)
        #expect(!feature.recordingConfirmationPresented && !window.isVisible)
        await feature.shutdownAndWait()
    }
    @Test func consentCancellationNeverReadsAndConfirmationStartsAfterCurrentContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-clipboard-consent-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MemoryClipboardSource()
        source.value = .init(generation: 1, items: [.text("before consent")], application: "test.app")
        let feature = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter())
        #expect(!feature.controller.enabled && source.reads == 0)
        feature.requestRecording()
        #expect(feature.recordingConfirmationPresented)
        feature.cancelRecording()
        await feature.confirmRecording(poll: false)?.value
        #expect(!feature.controller.enabled && source.reads == 0)
        feature.requestRecording()
        await feature.confirmRecording(poll: false)?.value
        #expect(feature.controller.enabled && !feature.recordingConfirmationPresented && !feature.recordingStarting)
        await feature.controller.refresh()
        #expect(feature.controller.entries.isEmpty && source.reads == 0)
        source.value = .init(generation: 2, items: [.text("after consent")], application: "test.app")
        await feature.controller.refresh()
        #expect(feature.controller.entries.map(\.plainText) == ["after consent"])
        feature.controller.pause()
        source.value = .init(generation: 3, items: [.text("during pause")], application: "test.app")
        await feature.controller.refresh()
        feature.controller.resume()
        await feature.controller.refresh()
        #expect(feature.controller.entries.map(\.plainText) == ["after consent"])
        await feature.shutdownAndWait()
        let nextRun = ClipboardFeature(directory: directory, source: source, writer: MemoryClipboardWriter())
        #expect(!nextRun.controller.enabled && !nextRun.recordingConfirmationPresented)
        await nextRun.shutdownAndWait()
    }
}

@MainActor private final class ConsentObservedSource: ClipboardSource {
    private(set) var baselineReads = 0
    private(set) var bodyReads = 0
    var generation: Int { baselineReads += 1; return 7 }
    func read(expectedGeneration: Int, excluding: Set<String>) -> V2ClipboardSnapshot? { bodyReads += 1; return nil }
}
private actor ConsentSuspendedArchive: V2ClipboardArchiving {
    private(set) var preferencesEntered = false
    private(set) var favoritesEntered = false
    private var preferencesReleased = false
    private var favoritesReleased = false
    private var preferencesWaiter: CheckedContinuation<ClipboardSettings?, Never>?
    private var favoritesWaiter: CheckedContinuation<[ClipboardEntry], Never>?
    func loadSettings() async -> ClipboardSettings? {
        preferencesEntered = true
        if preferencesReleased { return .init() }
        return await withCheckedContinuation { preferencesWaiter = $0 }
    }
    func loadFavorites() async -> [ClipboardEntry] {
        favoritesEntered = true
        if favoritesReleased { return [] }
        return await withCheckedContinuation { favoritesWaiter = $0 }
    }
    func releasePreferences() { preferencesReleased = true; preferencesWaiter?.resume(returning: .init()); preferencesWaiter = nil }
    func releaseFavorites() { favoritesReleased = true; favoritesWaiter?.resume(returning: []); favoritesWaiter = nil }
    func releaseAll() { releasePreferences(); releaseFavorites() }
    func load() -> [ClipboardEntry] { [] }
    func replace(_ entries: [ClipboardEntry], revision: UInt64) {}
    func clear(revision: UInt64) {}
    func saveSettings(_ settings: ClipboardSettings) {}
    func replaceFavorites(_ entries: [ClipboardEntry], revision: UInt64) {}
    func clearFavorites(revision: UInt64) {}
}
