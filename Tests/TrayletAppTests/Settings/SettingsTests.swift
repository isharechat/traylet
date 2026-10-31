import AppKit
import Testing
@testable import TrayletApp

@Suite("Settings") @MainActor struct SettingsTests {
    @Test func clickingASidebarRowShowsThatPaneImmediately() {
        let navigation = V2SettingsNavigation()
        #expect(navigation.current == .general)
        // One click is enough, in any order, including repeats and jumps to the last pane.
        for section in [V2SettingsSection.translation, .about, .about, .general, .clipboard, .shortcuts] {
            navigation.navigate(to: section)
            #expect(navigation.current == section)
        }
    }
}

@Suite("Settings Actions") @MainActor struct SettingsActionsTests {
    @Test func damagedPreferencesAreBackedUpOnlyOnExplicitRecoveryAndShortcutsRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-settings-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let damaged = Data("{ damaged new-version file".utf8)
        try damaged.write(to: file)
        let store = V2PreferencesStore(file: file); let driver = SettingsTestShortcutDriver()
        let manager = V2ShortcutManager(preferences: store, driver: driver)
        let actions = V2SettingsActions(preferences: store, login: SettingsTestLogin())
        #expect(store.failure != nil && driver.prepared == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
        actions.recoverPreferences(shortcuts: manager)
        #expect(store.failure == nil && actions.issue == nil && driver.prepared == 1)
        let backup = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("settings.json.recovery-") })
        #expect(try Data(contentsOf: backup) == damaged)
        #expect(try JSONDecoder().decode(V2UserPreferences.self, from: Data(contentsOf: file)) == V2UserPreferences())
    }
    @Test func rejectedRecoveryPreservesOriginalAndRegistrationFailureRemainsActionable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-settings-recovery-failure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("preserved.json")
        let original = Data("damaged".utf8); try original.write(to: target)
        let link = directory.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let rejected = V2PreferencesStore(file: link)
        let driver = SettingsTestShortcutDriver()
        let actions = V2SettingsActions(preferences: rejected, login: SettingsTestLogin())
        actions.recoverPreferences(shortcuts: V2ShortcutManager(preferences: rejected, driver: driver))
        #expect(rejected.failure != nil && actions.issue != nil && driver.prepared == 0)
        #expect(try Data(contentsOf: target) == original)
        let damaged = V2PreferencesStore(file: target)
        let recovery = V2SettingsActions(preferences: damaged, login: SettingsTestLogin())
        driver.reject = true
        recovery.recoverPreferences(shortcuts: V2ShortcutManager(preferences: damaged, driver: driver))
        #expect(damaged.failure == nil && recovery.issue != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("preserved.json.recovery-") })
    }
    @Test func pendingLoginApprovalRemainsVisibleAndCanBeTurnedOff() {
        let login = SettingsTestLogin(); login.requiresApproval = true
        let actions = V2SettingsActions(preferences: V2PreferencesStore(), login: login)
        #expect(actions.loginEnabled && actions.loginRequiresApproval)
        #expect(login.changes.isEmpty)
        actions.setLoginEnabled(false)
        #expect(!actions.loginEnabled && !actions.loginRequiresApproval)
        #expect(login.changes == [false])
    }
    @Test func preferenceWriteFailurePreservesTheDisplayedValueAndReportsRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-settings-failure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("blocked")
        try Data("file instead of directory".utf8).write(to: blocked)
        let store = V2PreferencesStore(file: blocked.appendingPathComponent("settings.json"))
        let login = SettingsTestLogin()
        let actions = V2SettingsActions(preferences: store, login: login)
        actions.setAppearance(.dark)
        #expect(store.value.appearance == .system)
        #expect(actions.issue != nil && login.changes.isEmpty)
    }
    @Test func onlyUserActionChangesLoginAndPreferenceFailuresRemainVisible() throws {
        let store = V2PreferencesStore()
        let login = SettingsTestLogin()
        let actions = V2SettingsActions(preferences: store, login: login)
        #expect(login.changes.isEmpty)
        actions.setAppearance(.dark)
        actions.setLanguage(.english)
        actions.setGlass(true)
        #expect(store.value.appearance == .dark && store.value.language == .english && store.value.glassEnabled)
        #expect(login.changes.isEmpty)
        actions.setLoginEnabled(true)
        #expect(login.changes == [true] && actions.loginEnabled)
        login.reject = true
        actions.setLoginEnabled(false)
        #expect(actions.loginEnabled)
        #expect(actions.issue != nil)
    }
}

@MainActor private final class SettingsTestLogin: V2LoginItemManaging {
    var enabled = false
    var requiresApproval = false
    var changes: [Bool] = []
    var reject = false
    func setEnabled(_ value: Bool) throws {
        if reject { throw CocoaError(.featureUnsupported) }
        enabled = value; requiresApproval = false; changes.append(value)
    }
}

@Suite("Settings Recorder") @MainActor struct SettingsRecorderTests {
    @Test func hardwareCodeIgnoresCharactersEscapeCancelsAndFailureRetainsTheBinding() throws {
        let store = V2PreferencesStore(); let driver = SettingsTestShortcutDriver()
        let manager = V2ShortcutManager(preferences: store, driver: driver)
        let recorder = V2ShortcutRecorder(manager: manager)
        try manager.start()
        manager.begin(.screenCapture)
        #expect(recorder.handle(try event(code: 0, characters: "任意布局", flags: [.control, .option, .capsLock])))
        #expect(store.value.shortcuts.first { $0.action == .screenCapture }?.chord == V2KeyChord(keyCode: 0, modifiers: [.control, .option]))
        manager.begin(.clipboard)
        #expect(recorder.handle(try event(code: 53, characters: "", flags: [])))
        #expect(manager.recordingAction == nil)
        #expect(!recorder.handle(try event(code: 1, characters: "s", flags: [.command])))
        let previous = store.value.shortcuts
        driver.reject = true
        manager.begin(.clipboard)
        #expect(recorder.handle(try event(code: 1, characters: "s", flags: [.command])))
        #expect(store.value.shortcuts == previous && manager.message != nil)
    }
    private func event(code: UInt16, characters: String, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
}
@MainActor private final class SettingsTestShortcutDriver: V2ShortcutRegistering {
    var onInvoke: ((V2Action) -> Void)?
    var reject = false
    var prepared = 0
    func prepare(_ bindings: [V2ShortcutAssignment]) throws -> any V2ShortcutUpdate {
        prepared += 1
        if reject { throw CocoaError(.featureUnsupported) }
        return SettingsTestShortcutUpdate()
    }
    func stop() {}
}
@MainActor private final class SettingsTestShortcutUpdate: V2ShortcutUpdate { func commit() {}; func cancel() {} }

@Suite("Settings Native Responder") @MainActor struct SettingsResponderTests {
    @Test func commandEquivalentIsConsumedOnlyDuringRecordingAndFocusReturnsAfterwards() throws {
        _ = NSApplication.shared
        let store = V2PreferencesStore(); let manager = V2ShortcutManager(preferences: store, driver: SettingsTestShortcutDriver())
        let recorder = V2ShortcutRecordingResponder.RecorderView(manager: manager)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        container.addSubview(field); container.addSubview(recorder)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = container
        defer { window.close() }
        window.makeFirstResponder(field)
        let original = window.firstResponder
        manager.begin(.screenCapture); recorder.setRecording(true)
        #expect(window.firstResponder === recorder)
        let command = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
        #expect(recorder.performKeyEquivalent(with: command))
        #expect(store.value.shortcuts.first { $0.action == .screenCapture }?.chord == V2KeyChord(keyCode: 12, modifiers: [.command]))
        recorder.setRecording(false)
        #expect(window.firstResponder === original)
        #expect(!window.isVisible)
    }
}

@Suite("Settings Lifecycle") @MainActor struct SettingsLifecycleTests {
    @Test func actualHiddenSettingsWindowCloseWithdrawsPendingConsent() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-hidden-settings-close-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clipboard = ClipboardFeature(directory: directory, source: SettingsTestClipboardSource(), writer: SettingsTestClipboardWriter())
        let store = V2PreferencesStore(), login = SettingsTestLogin()
        let manager = V2ShortcutManager(preferences: store, driver: SettingsTestShortcutDriver())
        var nativeWindow: NSWindow?
        let controller = V2SettingsController(preferences: store, shortcuts: manager, translation: TranslationConfiguration(), clipboard: clipboard,
                                              login: login, presentWindow: { nativeWindow = $0 })
        controller.present(section: .clipboard)
        let window = try #require(nativeWindow)
        #expect(!window.isVisible && !controller.isOpen && login.changes.isEmpty)
        clipboard.requestRecording()
        // Keep the host hidden; this exercises the real close/delegate path, not a displayed alert.
        clipboard.recordingConfirmationBinding.wrappedValue = false
        window.close()
        #expect(clipboard.confirmRecording(poll: false) == nil)
        #expect(!clipboard.controller.enabled && !window.isVisible)
        await clipboard.shutdownAndWait()
    }
    @Test func conflictSurvivesSheetFocusAndCloseCancelsRecordingAndPendingPreview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-settings-lifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clipboard = ClipboardFeature(directory: directory, source: SettingsTestClipboardSource(), writer: SettingsTestClipboardWriter())
        let store = V2PreferencesStore(); let manager = V2ShortcutManager(preferences: store, driver: SettingsTestShortcutDriver())
        let translation = TranslationConfiguration()
        let controller = V2SettingsController(preferences: store, shortcuts: manager, translation: translation, clipboard: clipboard)
        let original = store.value.shortcuts
        manager.begin(.screenCapture)
        manager.record(try #require(original.first { $0.action == .regionCapture }?.chord))
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        #expect(manager.conflict != nil)
        translation.request(.models)
        #expect(translation.preview != nil)
        clipboard.requestRecording()
        clipboard.recordingConfirmationBinding.wrappedValue = false
        controller.close()
        #expect(clipboard.confirmRecording(poll: false) == nil && !clipboard.controller.enabled)
        #expect(manager.recordingAction == nil && manager.conflict == nil)
        #expect(translation.preview == nil && !translation.isBusy)
        #expect(!controller.isOpen && store.value.shortcuts == original)
        await clipboard.shutdownAndWait()
    }
}
@MainActor private final class SettingsTestClipboardSource: ClipboardSource {
    var generation = 0
    func read(expectedGeneration: Int, excluding: Set<String>) -> V2ClipboardSnapshot? { nil }
}
@MainActor private final class SettingsTestClipboardWriter: ClipboardWriting {
    func write(_ items: [ClipboardContent], marker: String) -> ClipboardWriteResult { .failed }
}

@Suite("Settings Localization") @MainActor struct SettingsLocalizationTests {
    @Test func englishAndSystemWindowTitleUseTheSharedLanguageResolver() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-settings-language-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clipboard = ClipboardFeature(directory: directory, source: SettingsTestClipboardSource(), writer: SettingsTestClipboardWriter())
        let preferences = V2PreferencesStore()
        let shortcuts = V2ShortcutManager(preferences: preferences, driver: SettingsTestShortcutDriver())
        let localization = V2Localization(preferredLanguages: { ["de-DE", "en-US", "zh-Hans"] })
        let controller = V2SettingsController(preferences: preferences, shortcuts: shortcuts, translation: TranslationConfiguration(), clipboard: clipboard, localization: localization)
        #expect(controller.windowTitle == "Traylet · Settings")
        localization.languageCode = "zh-Hans"
        #expect(controller.windowTitle == "Traylet · 设置")
        localization.languageCode = "en"
        #expect(controller.windowTitle == "Traylet · Settings")
        localization.languageCode = ""
        #expect(localization.english && controller.windowTitle == "Traylet · Settings")
        let chineseSystem = V2Localization(preferredLanguages: { ["fr-FR", "zh-Hant", "en"] })
        let chineseController = V2SettingsController(preferences: preferences, shortcuts: shortcuts, translation: TranslationConfiguration(), clipboard: clipboard, localization: chineseSystem)
        #expect(!chineseSystem.english && chineseController.windowTitle == "Traylet · 设置")
        #expect(!controller.isOpen && !chineseController.isOpen)
        await clipboard.shutdownAndWait()
    }
}
