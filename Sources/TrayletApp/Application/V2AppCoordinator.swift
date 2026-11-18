import AppKit
import SwiftUI
import Combine
import TrayletCore

@MainActor final class V2AppCoordinator: NSObject, NSMenuDelegate {
    let preferences: V2PreferencesStore
    let shortcuts: V2ShortcutManager
    let translation: TranslationController
    let clipboard: ClipboardFeature
    let editor: CaptureEditorController
    let capture: V2CaptureSession
    let settings: V2SettingsController
    let clipboardEditing: ClipboardEditorBridge
    let clipboardTranslation: ClipboardTranslationBridge
    let permissionStatus: V2PermissionStatus
    private var permissionRecovery: V2PermissionRecovery!
    private var statusItem: NSStatusItem?
    private var welcome: NSWindow?
    private var recoveryWindow: NSWindow?
    private var progress: NSPanel?
    private var observations: Set<AnyCancellable> = []
    private var previousApp: NSRunningApplication?
    private weak var previousWindow: NSWindow?
    private var terminating = false
    private var authorizationTimer: Timer?
    private var requestedAccessibility = false
    let selectedText: any V2SelectedTextReading
    private var accessibilityGranted = false
    private var welcomeBacking: V2GlassWindowBacking?
    private var screenRecordingGranted = false

    static var dataRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Traylet/v2", isDirectory: true)
    }
    init(directory: URL = V2AppCoordinator.dataRoot) {
        let preferences = V2PreferencesStore(file: directory.appendingPathComponent("preferences.json"))
        let configuration = TranslationConfiguration(storageURL: directory.appendingPathComponent("translation.json"),
                                                     credentialStore: KeychainTranslationCredentialStore())
        let shortcuts = V2ShortcutManager(preferences: preferences, driver: V2TransactionalShortcutDriver(), unavailable: V2KeyChord.unavailableReason)
        // Recording is always on for the whole run; there is no user on/off or pause. It stops only on quit.
        let clipboard = ClipboardFeature(directory: directory.appendingPathComponent("clipboard", isDirectory: true), autoStart: true)
        self.preferences = preferences; self.shortcuts = shortcuts; self.clipboard = clipboard
        let setIgnoringNextCopy: (Bool) -> Void = { clipboard.controller.setIgnoringNextCopy($0) }
        let copyCapture = V2ClipboardCopyCapture(setIgnoringNextCopy: setIgnoringNextCopy)
        self.selectedText = V2SelectedTextStrategyChain(strategies: [
            V2AccessibilitySelectedText(),
            V2AppleScriptSelectedText(),
            V2MenuActionSelectedText(capture: copyCapture),
            V2SimulatedCopySelectedText(capture: copyCapture)
        ])
        let translation = TranslationController(configuration: configuration)
        self.translation = translation
        let editor = CaptureEditorController(), capture = V2CaptureSession()
        self.editor = editor; self.capture = capture
        clipboardEditing = ClipboardEditorBridge(clipboard: clipboard, editor: editor, canPresent: {
            editor.discardHiddenSession(); return !capture.isBusy
        })
        clipboardTranslation = ClipboardTranslationBridge(clipboard: clipboard, translation: translation, canPresent: {
            editor.discardHiddenSession(); return !capture.isBusy && !editor.isOpen
        })
        settings = V2SettingsController(preferences: preferences, shortcuts: shortcuts, translation: configuration, clipboard: clipboard)
        let permissionStatus = V2PermissionStatus()
        self.permissionStatus = permissionStatus
        super.init()
        permissionRecovery = V2PermissionRecovery(
            snapshotStore: V2PermissionSnapshotStore(file: directory.appendingPathComponent("permissions.json")),
            status: permissionStatus,
            present: { [weak self] losses in self?.presentPermissionRecovery(losses: losses) })
        shortcuts.onInvoke = { [weak self] in self?.invoke($0) }
        translation.onOpenSettings = { [weak self] pair in self?.settings.present(section: .translation, languagePackPair: pair) }
        editor.onComplete = { [weak self] in
            guard let self, !self.terminating else { return }
            if !self.clipboardEditing.complete() { self.restoreFocus() }
        }
        editor.onTranslate = { [weak self] image in
            self?.clipboardEditing.abandon()
            self?.previousApp = nil; self?.previousWindow = nil; self?.translation.present(image: image)
        }
        preferences.$value.sink { [weak self] value in
            V2AppearanceState.shared.glassEnabled = value.glassEnabled
            switch value.language {
            case .system: V2Localization.shared.languageCode = ""
            case .simplifiedChinese: V2Localization.shared.languageCode = "zh-Hans"
            case .english: V2Localization.shared.languageCode = "en"
            }
            switch value.appearance {
            case .system: NSApp.appearance = nil
            case .light: NSApp.appearance = NSAppearance(named: .aqua)
            case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
            }
            self?.refreshMenu(value: value)
        }.store(in: &observations)
    }

    func launch() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        NSApp.applicationIconImage = V2Brand.icon
        item.button?.image = V2Brand.mark()
        item.button?.image?.isTemplate = true; item.button?.toolTip = "Traylet"
        statusItem = item; refreshMenu(); refreshApplicationMenu()
        do { try shortcuts.start() }
        catch { showProblem((error as? FeatureIssue)?.localizedDescription ?? "全局快捷键未就绪，请从菜单栏打开设置。") }
        if !preferences.value.hasCompletedWelcome { showWelcome() }
        _ = permissionRecovery.runStartupCheck(hasCompletedWelcome: preferences.value.hasCompletedWelcome)
    }
    private var english: Bool { V2Localization.shared.english }
    private func refreshMenu(value: V2UserPreferences? = nil) {
        guard let statusItem else { return }
        let current = value ?? preferences.value
        let menu = V2MenuFactory.make(bindings: current.shortcuts, english: english, target: self, action: #selector(menuAction(_:)))
        menu.delegate = self; statusItem.menu = menu
        refreshApplicationMenu()
    }
    private func refreshApplicationMenu() {
        let bar = NSMenu()
        let application = NSMenuItem(); bar.addItem(application)
        let submenu = NSMenu(title: "Traylet"); application.submenu = submenu
        for (title, id, key) in [(V2L("设置"), "settings", ","), (V2L("退出"), "quit", "q")] {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command]; item.target = self; item.representedObject = id; submenu.addItem(item)
        }
        let editing = NSMenuItem(title: V2L("编辑"), action: nil, keyEquivalent: ""); bar.addItem(editing)
        let edit = NSMenu(title: editing.title); editing.submenu = edit
        for (title, selector, key) in [(V2L("撤销"), "undo:", "z"), (V2L("重做"), "redo:", "Z"),
                                     (V2L("剪切"), "cut:", "x"), (V2L("复制"), "copy:", "c"),
                                     (V2L("粘贴"), "paste:", "v"), (V2L("全选"), "selectAll:", "a")] {
            let item = NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key.lowercased())
            item.keyEquivalentModifierMask = key == "Z" ? [.command, .shift] : [.command]; edit.addItem(item)
        }
        NSApp.mainMenu = bar
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if let action = V2Action(rawValue: id) { invoke(action) }
        else if id == "settings" { settings.present() }
        else if id == "quit" { NSApp.terminate(nil) }
    }
    func invoke(_ action: V2Action) {
        guard !terminating, shortcuts.recordingAction == nil, shortcuts.conflict == nil else { return }
        guard V2AuthorizationGate.allowsFeatures(welcomeCompleted: preferences.value.hasCompletedWelcome) else { showWelcome(); return }
        editor.discardHiddenSession()
        guard !editor.isOpen, !capture.isBusy else { NSSound.beep(); return }
        switch action {
        case .inputTranslation:
            let needsAccessibility = !selectedText.isAuthorized
            if needsAccessibility, !requestedAccessibility {
                requestedAccessibility = true
                V2AccessibilitySelectedText.requestTrust()
            }
            // Resolve before presenting: presenting activates Traylet, and every strategy rejects
            // reading the selection from Traylet itself.
            V2InputTranslationResolver.resolve(
                reader: selectedText,
                translation: translation,
                needsAccessibility: needsAccessibility,
                isTerminated: { [weak self] in self?.terminating ?? true }
            )
        case .clipboard: clipboard.present()
        case .regionCapture, .screenCapture, .captureTranslation: startCapture(action)
        }
    }
    private func startCapture(_ action: V2Action) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main,
              let target = V2CaptureTarget(screen: screen) else { showProblem("没有可用的屏幕。"); return }
        previousApp = NSWorkspace.shared.frontmostApplication; previousWindow = NSApp.keyWindow
        // Fast captures go straight to the editor; the progress panel only appears when capture is slow.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.capture.isBusy, self.progress == nil else { return }
            self.showCaptureProgress()
        }
        capture.start(target) { [weak self, weak screen] result in
            guard let self else { return }
            self.progress?.close(); self.progress = nil
            switch result {
            case .success(let capture):
                guard let screen, V2CaptureTarget(screen: screen) == target else {
                    self.showProblem("目标屏幕已改变，请重新截图。"); return
                }
                self.editor.present(image: capture.image, decoded: capture.pixels, screen: screen, initiallyFullScreen: action == .screenCapture,
                    selectingForTranslation: action == .captureTranslation)
            case .failure(let error):
                self.restoreFocus()
                if case FeatureIssue.cancelled = error { return }
                self.showProblem((error as? FeatureIssue)?.localizedDescription ?? "无法截图，请检查屏幕录制权限并重试。")
            }
        }
    }
    private func showCaptureProgress() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 110), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.title = "Traylet"
        panel.contentView = NSHostingView(rootView:
            VStack(spacing: 16) {
                HStack { ProgressView().controlSize(.small); Text(V2L("正在准备截图…")) }
                Button(V2L("取消")) { [weak self] in self?.capture.cancel() }.keyboardShortcut(.cancelAction)
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity))
        panel.center(); progress = panel
        panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func restoreFocus() {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
            previousApp = nil; previousWindow = nil; return
        }
        if let previousWindow, previousWindow.isVisible { previousWindow.makeKeyAndOrderFront(nil) }
        else if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp.activate() }
        previousApp = nil; previousWindow = nil
    }
    func openPermissions() {
        V2PermissionStatus.openScreenRecordingSettings()
    }
    private func presentPermissionRecovery(losses: V2PermissionLoss) {
        if recoveryWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = english ? "Permissions" : "权限"
            window.isReleasedWhenClosed = false
            window.center()
            recoveryWindow = window
        }
        let hosting = NSHostingView(rootView: V2PermissionRecoveryView(
            status: permissionStatus,
            losses: losses,
            english: english,
            onLater: { [weak self] in self?.recoveryWindow?.close() }))
        recoveryWindow?.contentView = hosting
        recoveryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess(), !CGRequestScreenCaptureAccess() { openPermissions() }
        refreshAuthorization()
    }
    func completeWelcome() {
        guard V2AuthorizationGate.canComplete(screenRecordingGranted: CGPreflightScreenCaptureAccess()) else { refreshAuthorization(); return }
        do {
            var value = preferences.value; value.hasCompletedWelcome = true
            try preferences.save(value)
            authorizationTimer?.invalidate(); authorizationTimer = nil; welcome?.close()
        } catch { showProblem("首次运行状态未保存，原设置保持不变。") }
    }
    private func refreshAuthorization() {
        let granted = CGPreflightScreenCaptureAccess(), accessible = V2AccessibilitySelectedText.isTrusted
        guard granted != screenRecordingGranted || accessible != accessibilityGranted || welcome?.contentView == nil else { return }
        screenRecordingGranted = granted; accessibilityGranted = accessible
        renderWelcome()
    }
    private func renderWelcome() {
        let hosting = NSHostingView(rootView: V2WelcomeView(english: english, screenRecordingGranted: screenRecordingGranted, accessibilityGranted: accessibilityGranted,
            requestScreenRecording: { [weak self] in self?.requestScreenRecording() },
            requestAccessibility: { V2AccessibilitySelectedText.requestTrust() },
            openPermissions: { [weak self] in self?.openPermissions() }, complete: { [weak self] in self?.completeWelcome() }))
        guard let welcome else { return }
        if let welcomeBacking { welcomeBacking.replaceContent(hosting) } else { welcomeBacking = V2GlassWindowBacking(window: welcome, content: hosting) }
    }
    private func showWelcome() {
        if welcome == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Traylet"; window.isReleasedWhenClosed = false
            window.center(); welcome = window
            screenRecordingGranted = CGPreflightScreenCaptureAccess(); accessibilityGranted = V2AccessibilitySelectedText.isTrusted; renderWelcome()
        }
        authorizationTimer?.invalidate()
        authorizationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAuthorization() }
        }
        welcome?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func showProblem(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Traylet"; alert.informativeText = message
        alert.informativeText = V2L(message)
        alert.addButton(withTitle: english ? "OK" : "好")
        if message.contains("屏幕") && message.contains("权限") {
            alert.addButton(withTitle: V2L("请求屏幕录制权限"))
            if alert.runModal() == .alertSecondButtonReturn {
                if !CGRequestScreenCaptureAccess() { openPermissions() }
            }
        } else { alert.runModal() }
    }
    func requestTermination() -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        editor.discardHiddenSession()
        if editor.isOpen {
            let alert = NSAlert(); alert.messageText = V2L("放弃当前截图并退出？")
            alert.informativeText = V2L("未保存的编辑会丢失。")
            alert.addButton(withTitle: V2L("取消")); alert.addButton(withTitle: V2L("放弃并退出"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        terminating = true; clipboardEditing.abandon(); capture.cancel(); editor.cancel(restoreFocus:false); shortcuts.stop(); translation.close(); settings.close()
        Task { await clipboard.shutdownAndWait(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

enum V2AuthorizationGate {
    static func allowsFeatures(welcomeCompleted: Bool) -> Bool { welcomeCompleted }
    static func canComplete(screenRecordingGranted: Bool) -> Bool { screenRecordingGranted }
}

struct V2WelcomeView: View {
    let english: Bool
    var screenRecordingGranted = false
    var accessibilityGranted = false
    var requestScreenRecording: () -> Void = {}
    var requestAccessibility: () -> Void = {}
    let openPermissions: () -> Void
    let complete: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: V2Design.Space.l) {
            HStack(spacing: V2Design.Space.s) { V2BrandIcon(size: 48); Text("Traylet").font(.largeTitle.weight(.semibold)) }
            V2SettingsGroup(footer: screenRecordingGranted ? nil : (english ? "If the status does not update, reopen Traylet." : "若状态未更新，请重新打开 Traylet。")) {
                permissionRow(.screenRecording, granted: screenRecordingGranted, prominent: true, action: requestScreenRecording)
                Divider()
                permissionRow(.accessibility, granted: accessibilityGranted, prominent: false, action: requestAccessibility)
            }
            Spacer(minLength: 0)
            HStack {
                Button(english ? "Open Screen Recording Settings" : "打开屏幕录制设置", action: openPermissions)
                Spacer()
                Button(english ? "Get Started" : "开始使用", action: complete).buttonStyle(.borderedProminent)
                    .disabled(!V2AuthorizationGate.canComplete(screenRecordingGranted: screenRecordingGranted))
            }
        }.padding(V2Design.Space.xl + 4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func permissionRow(_ kind: V2PermissionKind, granted: Bool, prominent: Bool, action: @escaping () -> Void) -> some View {
        V2PermissionRow(symbol: kind.symbol, title: kind.title(english: english), detail: kind.shortDetail(english: english), granted: granted) {
            if !granted {
                if prominent {
                    Button(english ? "Allow…" : "允许…", action: action).buttonStyle(.borderedProminent)
                } else {
                    Button(english ? "Allow…" : "允许…", action: action)
                }
            }
        }
    }
}
