import AppKit
import SwiftUI
import Combine

@MainActor final class SettingsController: NSObject, NSWindowDelegate {
    let navigation = SettingsNavigation()
    let actions: SettingsActions
    let updater: UpdateController
    let languagePacks = TranslationLanguagePackController()
    private let preferences: PreferencesStore
    private let shortcuts: ShortcutManager
    private let ocr: OCRConfiguration
    private let translation: TranslationConfiguration
    private let clipboard: ClipboardFeature
    private let localization: Localization
    private let presentWindow: (NSWindow) -> Void
    private let onRequestQuitForUpdate: @MainActor () -> Void
    private var window: NSWindow?
    private var backing: GlassWindowBacking?
    private var dismissal: NSObjectProtocol?
    private var appearanceObservation: AnyCancellable?
    private var localizationObservation: AnyCancellable?
    var isOpen: Bool { window?.isVisible == true }
    var windowTitle: String { "Traylet · " + (localization.english ? "Settings" : "设置") }

    init(preferences: PreferencesStore, shortcuts: ShortcutManager, ocr: OCRConfiguration = OCRConfiguration(), translation: TranslationConfiguration, clipboard: ClipboardFeature, localization: Localization = .shared,
         login: any LoginItemManaging = SystemLoginItem(),
         actions: SettingsActions? = nil,
         updater: UpdateController? = nil,
         onRequestQuitForUpdate: @MainActor @escaping () -> Void = { NSApp.terminate(nil) },
         presentWindow: @escaping (NSWindow) -> Void = { window in window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }) {
        self.preferences = preferences; self.shortcuts = shortcuts; self.ocr = ocr; self.translation = translation; self.clipboard = clipboard; self.localization = localization
        self.presentWindow = presentWindow
        self.onRequestQuitForUpdate = onRequestQuitForUpdate
        let resolvedActions = actions ?? SettingsActions(preferences: preferences, login: login)
        self.actions = resolvedActions
        self.updater = updater ?? UpdateController(preferences: preferences, actions: resolvedActions)
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
    func present(section: SettingsSection = .general, languagePackPair: TranslationLanguagePackPair? = nil) {
        if let languagePackPair { languagePacks.apply(languagePackPair) }
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 650), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            created.title = windowTitle; created.minSize = NSSize(width: 560, height: 420)
            created.isReleasedWhenClosed = false; created.hidesOnDeactivate = false; created.delegate = self
            let hosting = NSHostingView(rootView: SettingsWorkspaceView(preferences: preferences, shortcuts: shortcuts, ocr: ocr, translation: translation, languagePacks: languagePacks, clipboard: clipboard, navigation: navigation, actions: actions, updater: updater, onRequestQuitForUpdate: onRequestQuitForUpdate, localization: localization))
            created.appearance = Self.appearance(preferences.value.appearance)
            backing = GlassWindowBacking(window: created, content: hosting)
            created.center(); window = created
            dismissal = FloatingWindow.hideOnResignKey(created, canHide: { [weak self] in self?.languagePacks.isDownloading != true }) { [weak self] in
                self?.shortcuts.cancel(); self?.ocr.cancel(); self?.translation.cancel(); self?.languagePacks.cancel(); self?.window?.orderOut(nil)
            }
        }
        actions.refreshLoginStatus()
        navigation.navigate(to: section)
        if let window { presentWindow(window) }
    }
    func close() { shortcuts.cancel(); ocr.cancel(); translation.cancel(); languagePacks.cancel(); window?.close() }
    func windowWillClose(_ notification: Notification) { shortcuts.cancel(); ocr.cancel(); translation.cancel(); languagePacks.cancel() }
    func windowDidResignKey(_ notification: Notification) {
        // A conflict alert may take key focus; preserve its three explicit choices.
        if shortcuts.conflict == nil { shortcuts.cancel() }
    }
    private static func appearance(_ value: Appearance) -> NSAppearance? {
        switch value { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
    }
}
