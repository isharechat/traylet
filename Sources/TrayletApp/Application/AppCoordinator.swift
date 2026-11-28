import AppKit
import SwiftUI
import Combine
import TrayletCore

@MainActor final class AppCoordinator: NSObject, NSMenuDelegate {
    let preferences: PreferencesStore
    let shortcuts: ShortcutManager
    let translation: TranslationController
    let ocr: OCRController
    let clipboard: ClipboardFeature
    let editor: CaptureEditorController
    let capture: CaptureSession
    let settings: SettingsController
    let updater: UpdateController
    let clipboardEditing: ClipboardEditorBridge
    let clipboardTranslation: ClipboardTranslationBridge
    let permissionStatus: PermissionStatus
    private var permissionRecovery: PermissionRecovery!
    private var statusItem: NSStatusItem?
    private var welcome: NSWindow?
    private var recoveryWindow: NSWindow?
    private var progress: NSPanel?
    private var observations: Set<AnyCancellable> = []
    private var previousApp: NSRunningApplication?
    private weak var previousWindow: NSWindow?
    private var terminating = false
    private var confirmingTermination = false
    private var authorizationTimer: Timer?
    private var requestedAccessibility = false
    var selectedText: any SelectedTextReading
    var shutdownTimeoutNanoseconds: UInt64 = 5_000_000_000
    var finishTermination: @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }
    var confirmQuitWithOpenEditor: (@MainActor () -> Bool)?
    private var welcomeBacking: GlassWindowBacking?
    private var recoveryBacking: GlassWindowBacking?
    private var screenRecordingGranted = false

    static var dataRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Traylet/v2", isDirectory: true)
    }
    init(directory: URL = AppCoordinator.dataRoot) {
        let preferences = PreferencesStore(file: directory.appendingPathComponent("preferences.json"))
        let credentialVault = LocalEncryptedCredentialVault(directory: directory)
        let configuration = TranslationConfiguration(storageURL: directory.appendingPathComponent("translation.json"),
                                                     credentialStore: LocalTranslationCredentialStore(vault: credentialVault))
        let shortcuts = ShortcutManager(preferences: preferences, driver: TransactionalShortcutDriver(), unavailable: KeyChord.unavailableReason)
        // Recording is always on for the whole run; there is no user on/off or pause. It stops only on quit.
        let clipboard = ClipboardFeature(directory: directory.appendingPathComponent("clipboard", isDirectory: true), autoStart: true)
        self.preferences = preferences; self.shortcuts = shortcuts; self.clipboard = clipboard
        let setIgnoringNextCopy: (Bool) -> Void = { clipboard.controller.setIgnoringNextCopy($0) }
        let copyCapture = ClipboardCopyCapture(setIgnoringNextCopy: setIgnoringNextCopy)
        self.selectedText = SelectedTextStrategyChain(strategies: [
            AccessibilitySelectedText(),
            AppleScriptSelectedText(),
            MenuActionSelectedText(capture: copyCapture),
            SimulatedCopySelectedText(capture: copyCapture)
        ])
        let translation = TranslationController(configuration: configuration)
        self.translation = translation
        let ocrConfiguration = OCRConfiguration(
            storageURL: directory.appendingPathComponent("ocr.json"),
            credentialStore: LocalOCRCredentialStore(vault: credentialVault)
        )
        let ocr = OCRController(configuration: ocrConfiguration)
        self.ocr = ocr
        let editor = CaptureEditorController(), capture = CaptureSession()
        self.editor = editor; self.capture = capture
        clipboardEditing = ClipboardEditorBridge(clipboard: clipboard, editor: editor, canPresent: {
            editor.discardHiddenSession(); return !capture.isBusy
        })
        clipboardTranslation = ClipboardTranslationBridge(clipboard: clipboard, translation: translation, canPresent: {
            editor.discardHiddenSession(); return !capture.isBusy && !editor.isOpen
        })
        let settingsActions = SettingsActions(preferences: preferences, login: SystemLoginItem())
        let updater = UpdateController(preferences: preferences, actions: settingsActions)
        self.updater = updater
        settings = SettingsController(
            preferences: preferences,
            shortcuts: shortcuts,
            ocr: ocrConfiguration,
            translation: configuration,
            clipboard: clipboard,
            actions: settingsActions,
            updater: updater,
            onRequestQuitForUpdate: { NSApp.terminate(nil) }
        )
        let permissionStatus = PermissionStatus()
        self.permissionStatus = permissionStatus
        super.init()
        permissionRecovery = PermissionRecovery(
            snapshotStore: PermissionSnapshotStore(file: directory.appendingPathComponent("permissions.json")),
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
        editor.onOCR = { [weak self] image, keepEditorOpen in
            if !keepEditorOpen {
                self?.clipboardEditing.abandon()
                self?.previousApp = nil; self?.previousWindow = nil
            }
            self?.ocr.present(image: image, autoRecognize: true, elevatedAboveEditor: keepEditorOpen)
        }
        ocr.onTranslate = { [weak self] text, image in
            self?.translation.present(text: text, sourceImage: image, autoSubmit: true)
        }
        ocr.onRecapture = { [weak self] in
            self?.invoke(.ocr)
        }
        ocr.onOpenSettings = { [weak self] in
            self?.settings.present(section: .ocr)
        }
        translation.onOpenOCR = { [weak self] image in
            self?.ocr.present(image: image, autoRecognize: image != nil)
        }
        translation.onCaptureOCR = { [weak self] in
            self?.invoke(.ocr)
        }
        translation.onOpenImageDataInOCR = { [weak self] data in
            self?.ocr.present(autoRecognize: false)
            self?.ocr.importImageData(data)
        }
        preferences.$value.sink { [weak self] value in
            AppearanceState.shared.glassEnabled = value.glassEnabled
            switch value.language {
            case .system: Localization.shared.languageCode = ""
            case .simplifiedChinese: Localization.shared.languageCode = "zh-Hans"
            case .english: Localization.shared.languageCode = "en"
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
        NSApp.applicationIconImage = Brand.icon
        item.button?.image = Brand.mark()
        item.button?.image?.isTemplate = true; item.button?.toolTip = "Traylet"
        statusItem = item; refreshMenu(); refreshApplicationMenu()
        do { try shortcuts.start() }
        catch { showProblem((error as? FeatureIssue)?.localizedDescription ?? "全局快捷键未就绪，请从菜单栏打开设置。") }
        if !preferences.value.hasCompletedWelcome {
            if CGPreflightScreenCaptureAccess() { completeWelcome() }
            else { showWelcome() }
        }
        _ = permissionRecovery.runStartupCheck(hasCompletedWelcome: preferences.value.hasCompletedWelcome)
        updater.startAutomaticCheckIfNeeded()
    }
    private var english: Bool { Localization.shared.english }
    private func refreshMenu(value: UserPreferences? = nil) {
        guard let statusItem else { return }
        let current = value ?? preferences.value
        let menu = MenuFactory.make(bindings: current.shortcuts, english: english, target: self, action: #selector(menuAction(_:)))
        menu.delegate = self; statusItem.menu = menu
        refreshApplicationMenu()
    }
    private func refreshApplicationMenu() {
        let bar = NSMenu()
        let application = NSMenuItem(); bar.addItem(application)
        let submenu = NSMenu(title: "Traylet"); application.submenu = submenu
        for (title, id, key) in [(L("设置"), "settings", ","), (L("退出"), "quit", "q")] {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command]; item.target = self; item.representedObject = id; submenu.addItem(item)
        }
        let editing = NSMenuItem(title: L("编辑"), action: nil, keyEquivalent: ""); bar.addItem(editing)
        let edit = NSMenu(title: editing.title); editing.submenu = edit
        for (title, selector, key) in [(L("撤销"), "undo:", "z"), (L("重做"), "redo:", "Z"),
                                     (L("剪切"), "cut:", "x"), (L("复制"), "copy:", "c"),
                                     (L("粘贴"), "paste:", "v"), (L("全选"), "selectAll:", "a")] {
            let item = NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key.lowercased())
            item.keyEquivalentModifierMask = key == "Z" ? [.command, .shift] : [.command]; edit.addItem(item)
        }
        NSApp.mainMenu = bar
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if let action = Action(rawValue: id) { invoke(action) }
        else if id == "settings" { settings.present() }
        else if id == "quit" { NSApp.terminate(nil) }
    }
    func invoke(_ action: Action) {
        guard !terminating, shortcuts.recordingAction == nil, shortcuts.conflict == nil else { return }
        guard AuthorizationGate.allowsFeatures(welcomeCompleted: preferences.value.hasCompletedWelcome) else { showWelcome(); return }
        editor.discardHiddenSession()
        guard !editor.isOpen, !capture.isBusy else { NSSound.beep(); return }
        switch action {
        case .inputTranslation:
            let needsAccessibility = !selectedText.isAuthorized
            if needsAccessibility, !requestedAccessibility {
                requestedAccessibility = true
                AccessibilitySelectedText.requestTrust()
            }
            // Resolve before presenting: presenting activates Traylet, and every strategy rejects
            // reading the selection from Traylet itself.
            InputTranslationResolver.resolve(
                reader: selectedText,
                translation: translation,
                needsAccessibility: needsAccessibility,
                isTerminated: { [weak self] in self?.terminating ?? true }
            )
        case .clipboard: clipboard.present()
        case .regionCapture, .screenCapture, .captureTranslation, .ocr: startCapture(action)
        }
    }
    private func startCapture(_ action: Action) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main,
              let target = CaptureTarget(screen: screen) else { showProblem("没有可用的屏幕。"); return }
        previousApp = NSWorkspace.shared.frontmostApplication; previousWindow = NSApp.keyWindow
        // Fast captures go straight to the editor; the progress panel only appears when capture is slow.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.terminating, self.capture.isBusy, self.progress == nil else { return }
            self.showCaptureProgress()
        }
        capture.start(target) { [weak self, weak screen] result in
            guard let self else { return }
            self.progress?.close(); self.progress = nil
            guard !self.terminating else { return }
            switch result {
            case .success(let capture):
                guard let screen, CaptureTarget(screen: screen) == target else {
                    self.showProblem("目标屏幕已改变，请重新截图。"); return
                }
                if let image = capture.image {
                    self.editor.present(image: image, decoded: capture.pixels, screen: screen, initiallyFullScreen: action == .screenCapture,
                        selectingForTranslation: action == .captureTranslation, selectingForOCR: action == .ocr)
                } else if let pixels = capture.pixels {
                    self.editor.present(pixels: pixels, screen: screen, initiallyFullScreen: action == .screenCapture,
                        selectingForTranslation: action == .captureTranslation, selectingForOCR: action == .ocr)
                } else {
                    self.showProblem("无法截图，请检查屏幕录制权限并重试。")
                }
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
                HStack { ProgressView().controlSize(.small); Text(L("正在准备截图…")) }
                Button(L("取消")) { [weak self] in self?.capture.cancel() }.keyboardShortcut(.cancelAction)
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
        PermissionStatus.openScreenRecordingSettings()
    }
    private func presentPermissionRecovery(losses: PermissionLoss) {
        if recoveryWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = english ? "Permissions" : "权限"
            window.isReleasedWhenClosed = false
            window.center()
            recoveryWindow = window
        }
        let hosting = NSHostingView(rootView: PermissionRecoveryView(
            status: permissionStatus,
            losses: losses,
            english: english,
            onLater: { [weak self] in self?.recoveryWindow?.close() }))
        if let recoveryBacking {
            recoveryBacking.replaceContent(hosting)
        } else if let recoveryWindow {
            recoveryBacking = GlassWindowBacking(window: recoveryWindow, content: hosting)
        }
        recoveryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func requestScreenRecording() {
        permissionStatus.requestScreenRecording()
        refreshAuthorization()
    }
    func completeWelcome() {
        guard AuthorizationGate.canComplete(screenRecordingGranted: CGPreflightScreenCaptureAccess()) else { refreshAuthorization(); return }
        do {
            var value = preferences.value; value.hasCompletedWelcome = true
            try preferences.save(value)
            authorizationTimer?.invalidate(); authorizationTimer = nil; welcome?.close()
        } catch { showProblem("首次运行状态未保存，原设置保持不变。") }
    }
    private func refreshAuthorization() {
        let granted = CGPreflightScreenCaptureAccess()
        if granted, !preferences.value.hasCompletedWelcome {
            completeWelcome()
            return
        }
        guard granted != screenRecordingGranted || welcome?.contentView == nil else { return }
        screenRecordingGranted = granted
        renderWelcome()
    }
    private func renderWelcome() {
        let hosting = NSHostingView(rootView: WelcomeView(english: english, screenRecordingGranted: screenRecordingGranted,
            requestScreenRecording: { [weak self] in self?.requestScreenRecording() },
            openPermissions: { [weak self] in self?.openPermissions() }, complete: { [weak self] in self?.completeWelcome() }))
        guard let welcome else { return }
        if let welcomeBacking { welcomeBacking.replaceContent(hosting) } else { welcomeBacking = GlassWindowBacking(window: welcome, content: hosting) }
    }
    private func showWelcome() {
        if welcome == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Traylet"; window.isReleasedWhenClosed = false
            window.center(); welcome = window
            screenRecordingGranted = CGPreflightScreenCaptureAccess(); renderWelcome()
        }
        authorizationTimer?.invalidate()
        authorizationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAuthorization() }
        }
        welcome?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func showProblem(_ message: String) {
        guard !terminating else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "Traylet"
        alert.informativeText = L(message)
        alert.addButton(withTitle: english ? "OK" : "好")
        raiseAlertAboveEditorIfNeeded(alert)
        if message.contains("屏幕") && message.contains("权限") {
            alert.addButton(withTitle: L("请求屏幕录制权限"))
            if alert.runModal() == .alertSecondButtonReturn {
                permissionStatus.requestScreenRecording()
            }
        } else { alert.runModal() }
    }
    private func raiseAlertAboveEditorIfNeeded(_ alert: NSAlert) {
        if let level = editor.windowLevel, level >= .modalPanel {
            alert.window.level = NSWindow.Level(rawValue: level.rawValue + 1)
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
    }
    func requestTermination() -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        guard !confirmingTermination else { return .terminateCancel }
        editor.discardHiddenSession()
        if editor.isOpen {
            confirmingTermination = true
            defer { confirmingTermination = false }
            let confirmed: Bool
            if let confirmQuitWithOpenEditor {
                confirmed = confirmQuitWithOpenEditor()
            } else {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert(); alert.messageText = L("放弃当前截图并退出？")
                alert.informativeText = L("未保存的编辑会丢失。")
                alert.addButton(withTitle: L("取消")); alert.addButton(withTitle: L("放弃并退出"))
                raiseAlertAboveEditorIfNeeded(alert)
                confirmed = alert.runModal() == .alertSecondButtonReturn
            }
            guard confirmed else { return .terminateCancel }
        }
        terminating = true
        authorizationTimer?.invalidate(); authorizationTimer = nil
        welcome?.close(); welcome = nil; welcomeBacking = nil
        recoveryWindow?.close(); recoveryWindow = nil; recoveryBacking = nil
        progress?.close(); progress = nil
        clipboardEditing.abandon(); capture.cancel()
        editor.cancel(restoreFocus: false); editor.closeFloatingPanels()
        updater.stopAutomaticChecks()
        shortcuts.stop(); ocr.close(); translation.close(); settings.close()
        startTerminationShutdown()
        return .terminateLater
    }
    private func startTerminationShutdown() {
        var replied = false
        let reply: @MainActor () -> Void = { [weak self] in
            guard !replied else { return }
            replied = true
            self?.finishTermination(true)
        }
        let timeout = shutdownTimeoutNanoseconds
        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled else { return }
            reply()
        }
        Task { @MainActor [weak self] in
            await self?.clipboard.shutdownAndWait()
            deadline.cancel()
            reply()
        }
    }
}

enum AuthorizationGate {
    static func allowsFeatures(welcomeCompleted: Bool) -> Bool { welcomeCompleted }
    static func canComplete(screenRecordingGranted: Bool) -> Bool { screenRecordingGranted }
}

struct WelcomeView: View {
    let english: Bool
    var screenRecordingGranted = false
    var requestScreenRecording: () -> Void = {}
    let openPermissions: () -> Void
    let complete: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.l) {
            HStack(spacing: Design.Space.m) {
                BrandIcon(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Traylet").font(.title2.weight(.bold))
                    Text(english ? "Capture, translate, and manage your clipboard from the menu bar." : "截图、翻译、剪贴板。轻巧常驻菜单栏。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            SettingsGroup(footer: screenRecordingGranted ? nil : (english ? "Traylet opens automatically once allowed. Reopen Traylet if the status does not update." : "授权后将自动进入 Traylet；若状态未更新，请重新打开 Traylet。")) {
                PermissionRow(
                    symbol: PermissionKind.screenRecording.symbol,
                    title: PermissionKind.screenRecording.title(english: english),
                    detail: PermissionKind.screenRecording.shortDetail(english: english),
                    granted: screenRecordingGranted
                ) {
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button(english ? "Open System Settings" : "打开系统设置", action: openPermissions)
                Spacer()
                if screenRecordingGranted {
                    Button(english ? "Get Started" : "开始使用", action: complete).buttonStyle(.borderedProminent)
                } else {
                    Button(english ? "Allow Screen Recording" : "允许屏幕录制", action: requestScreenRecording).buttonStyle(.borderedProminent)
                }
            }
        }.padding(Design.Space.xl).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
