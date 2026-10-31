import AppKit
import SwiftUI
import Testing
@testable import TrayletApp

@Suite("Settings Native Evidence") @MainActor struct SettingsVisualTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAYLET_SETTINGS_SNAPSHOT_DIR"] != nil))
    func renderAllAnchorsInLightDarkNarrowWideWithoutShowingWindow() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TRAYLET_SETTINGS_SNAPSHOT_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-settings-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let clipboard = ClipboardFeature(directory: temporary, source: SettingsVisualClipboardSource(), writer: SettingsVisualClipboardWriter())
        let store = V2PreferencesStore(); let driver = SettingsVisualShortcutDriver()
        let shortcuts = V2ShortcutManager(preferences: store, driver: driver)
        let translation = TranslationConfiguration()
        let actions = V2SettingsActions(preferences: store, login: SettingsVisualLogin())
        for scheme in [ColorScheme.light, .dark] {
            for (sizeName, size) in [("wide", CGSize(width: 780, height: 650)), ("narrow", CGSize(width: 560, height: 420))] {
                let navigation = V2SettingsNavigation()
                let view = V2SettingsWorkspaceView(preferences: store, shortcuts: shortcuts, translation: translation, clipboard: clipboard, navigation: navigation, actions: actions, localization: V2Localization(languageCode: "zh-Hans"))
                    .environment(\.colorScheme, scheme).transaction { $0.disablesAnimations = true }
                    .frame(width: size.width, height: size.height)
                let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                for section in V2SettingsSection.allCases {
                    navigation.navigate(to: section)
                    host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(350)); host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    #expect((bitmap.colorAt(x: bitmap.pixelsWide - 2, y: bitmap.pixelsHigh - 2)?.alphaComponent ?? 0) > 0.99, "A synthetic window snapshot must include its semantic window backdrop")
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    #expect(png.count > 5_000)
                    #expect(navigation.current == section)
                    try png.write(to: output.appendingPathComponent("settings-\(scheme == .dark ? "dark" : "light")-\(sizeName)-\(section.rawValue).png"))
                    #expect(!window.isVisible)
                }
                window.close()
            }
        }
        #expect(!clipboard.controller.enabled)
        #expect(translation.credential.isEmpty && !translation.isBusy)
        await clipboard.shutdownAndWait()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAYLET_SETTINGS_SNAPSHOT_DIR"] != nil))
    func renderEnglishAndSystemLanguageFallbackWithoutShowingWindow() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TRAYLET_SETTINGS_SNAPSHOT_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-settings-localized-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clipboard = ClipboardFeature(directory: directory, source: SettingsVisualClipboardSource(), writer: SettingsVisualClipboardWriter())
        for (name, code, languages, expectedEnglish) in [("english", "en", ["zh-Hans"], true), ("system-english", "", ["de-DE", "en-US"], true), ("system-chinese", "", ["fr-FR", "zh-Hant", "en-US"], false)] {
            let localization = V2Localization(languageCode: code, preferredLanguages: { languages })
            let store = V2PreferencesStore()
            var preferences = store.value; preferences.language = code == "en" ? .english : .system; try store.save(preferences)
            let shortcuts = V2ShortcutManager(preferences: store, driver: SettingsVisualShortcutDriver())
            let navigation = V2SettingsNavigation()
            let view = V2SettingsWorkspaceView(preferences: store, shortcuts: shortcuts, translation: TranslationConfiguration(), clipboard: clipboard, navigation: navigation, actions: V2SettingsActions(preferences: store, login: SettingsVisualLogin()), localization: localization)
                .environment(\.colorScheme, .light).frame(width: 560, height: 420)
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
            window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("settings-localized-\(name)-narrow.png"))
            #expect(localization.english == expectedEnglish && png.count > 5_000)
            #expect(!window.isVisible && !clipboard.controller.enabled)
            window.close()
        }
        await clipboard.shutdownAndWait()
    }
}
@MainActor private final class SettingsVisualLogin: V2LoginItemManaging {
    var enabled = false; var requiresApproval = false
    func setEnabled(_ value: Bool) throws { enabled = value }
}
@MainActor private final class SettingsVisualShortcutDriver: V2ShortcutRegistering {
    var onInvoke: ((V2Action) -> Void)?
    func prepare(_ bindings: [V2ShortcutAssignment]) throws -> any V2ShortcutUpdate { SettingsVisualShortcutUpdate() }
    func stop() {}
}
@MainActor private final class SettingsVisualShortcutUpdate: V2ShortcutUpdate { func commit() {}; func cancel() {} }
@MainActor private final class SettingsVisualClipboardSource: ClipboardSource {
    var generation = 0
    func read(expectedGeneration: Int, excluding: Set<String>) -> V2ClipboardSnapshot? { nil }
}
@MainActor private final class SettingsVisualClipboardWriter: ClipboardWriting {
    func write(_ items: [ClipboardContent], marker: String) -> ClipboardWriteResult { .failed }
}
