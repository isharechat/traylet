import AppKit
import SwiftUI
import Combine

@MainActor final class V2SettingsController: NSObject, NSWindowDelegate {
    let navigation = V2SettingsNavigation()
    let actions: V2SettingsActions
    let languagePacks = TranslationLanguagePackController()
    private let preferences: V2PreferencesStore
    private let shortcuts: V2ShortcutManager
    private let translation: TranslationConfiguration
    private let clipboard: ClipboardFeature
    private let localization: V2Localization
    private let presentWindow: (NSWindow) -> Void
    private var window: NSWindow?
    private var backing: V2GlassWindowBacking?
    private var dismissal: NSObjectProtocol?
    private var appearanceObservation: AnyCancellable?
    private var localizationObservation: AnyCancellable?
    var isOpen: Bool { window?.isVisible == true }
    var windowTitle: String { "Traylet · " + (localization.english ? "Settings" : "设置") }

    init(preferences: V2PreferencesStore, shortcuts: V2ShortcutManager, translation: TranslationConfiguration, clipboard: ClipboardFeature, localization: V2Localization = .shared,
         login: any V2LoginItemManaging = V2SystemLoginItem(),
         presentWindow: @escaping (NSWindow) -> Void = { window in window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }) {
        self.preferences = preferences; self.shortcuts = shortcuts; self.translation = translation; self.clipboard = clipboard; self.localization = localization
        self.presentWindow = presentWindow
        actions = V2SettingsActions(preferences: preferences, login: login)
        super.init()
        appearanceObservation = preferences.$value.sink { [weak self] value in
            self?.window?.appearance = Self.appearance(value.appearance)
            self?.window?.title = self?.windowTitle ?? ""
        }
        localizationObservation = localization.objectWillChange.sink { [weak self] _ in
            // Published emits before the new language is stored; update on the next actor turn.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.window?.title = self.windowTitle
            }
        }
    }
    func present(section: V2SettingsSection = .general, languagePackPair: TranslationLanguagePackPair? = nil) {
        if let languagePackPair { languagePacks.apply(languagePackPair) }
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 650), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            created.title = windowTitle; created.minSize = NSSize(width: 560, height: 420)
            created.isReleasedWhenClosed = false; created.delegate = self
            let hosting = NSHostingView(rootView: V2SettingsWorkspaceView(preferences: preferences, shortcuts: shortcuts, translation: translation, languagePacks: languagePacks, clipboard: clipboard, navigation: navigation, actions: actions, localization: localization))
            created.appearance = Self.appearance(preferences.value.appearance)
            backing = V2GlassWindowBacking(window: created, content: hosting)
            created.center(); window = created
            dismissal = V2FloatingWindow.hideOnResignKey(created) { [weak self] in self?.shortcuts.cancel(); self?.translation.cancel(); self?.window?.orderOut(nil) }
        }
        actions.refreshLoginStatus()
        navigation.navigate(to: section)
        if let window { presentWindow(window) }
    }
    func close() { shortcuts.cancel(); translation.cancel(); window?.close() }
    func windowWillClose(_ notification: Notification) { shortcuts.cancel(); translation.cancel() }
    func windowDidResignKey(_ notification: Notification) {
        // A conflict alert may take key focus; preserve its three explicit choices.
        if shortcuts.conflict == nil { shortcuts.cancel() }
    }
    private static func appearance(_ value: V2Appearance) -> NSAppearance? {
        switch value { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
    }
}
