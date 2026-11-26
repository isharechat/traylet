import AppKit
import SwiftUI

@MainActor struct SettingsWorkspaceView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var shortcuts: ShortcutManager
    @ObservedObject var translation: TranslationConfiguration
    let languagePacks: TranslationLanguagePackController
    let clipboard: ClipboardFeature
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var actions: SettingsActions
    @ObservedObject var updater: UpdateController
    var onRequestQuitForUpdate: @MainActor () -> Void
    @ObservedObject var localization: Localization

    init(
        preferences: PreferencesStore,
        shortcuts: ShortcutManager,
        translation: TranslationConfiguration,
        languagePacks: TranslationLanguagePackController,
        clipboard: ClipboardFeature,
        navigation: SettingsNavigation,
        actions: SettingsActions,
        updater: UpdateController? = nil,
        onRequestQuitForUpdate: @MainActor @escaping () -> Void = { NSApp.terminate(nil) },
        localization: Localization = .shared
    ) {
        self.preferences = preferences
        self.shortcuts = shortcuts
        self.translation = translation
        self.languagePacks = languagePacks
        self.clipboard = clipboard
        self.navigation = navigation
        self.actions = actions
        self.updater = updater ?? UpdateController(preferences: preferences, actions: actions)
        self.onRequestQuitForUpdate = onRequestQuitForUpdate
        self.localization = localization
    }
    @ObservedObject private var appearance = AppearanceState.shared
    @StateObject private var permissionStatus = PermissionStatus()
    @State private var confirmPreferenceRecovery = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var english: Bool { localization.english }
    private var usesGlass: Bool { appearance.glassActive && !reduceTransparency && contrast != .increased }
    private func text(_ chinese: String, _ english: String) -> String { self.english ? english : chinese }
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 0) {
                sidebar.frame(width: geometry.size.width < 650 ? (english ? 160 : 140) : 190)
                // Keep the column geometry while solid mode shares one uninterrupted surface.
                Divider().opacity(usesGlass ? 1 : 0)
                detail
            }
        }
        .background { if !usesGlass { Color(nsColor: .windowBackgroundColor) } }
        .background(ShortcutRecordingResponder(manager: shortcuts).frame(width: 0, height: 0))
        .preferredColorScheme(preferences.value.appearance == .system ? nil : preferences.value.appearance == .dark ? .dark : .light)
        .environment(\.locale, Locale(identifier: english ? "en" : "zh-Hans"))
        .alert(text("快捷键已被占用", "Shortcut already assigned"), isPresented: Binding(get: { shortcuts.conflict != nil }, set: { if !$0 && shortcuts.conflict != nil { shortcuts.keepExisting() } })) {
            Button(text("保留原绑定", "Keep existing"), role: .cancel) { shortcuts.keepExisting() }
            Button(text("替换原绑定", "Replace existing"), role: .destructive) { shortcuts.replaceExisting() }
            Button(text("重新录入", "Record another")) { shortcuts.retry() }
        } message: {
            if let conflict = shortcuts.conflict {
                Text("\(conflict.proposed.display) · \(actionTitle(conflict.occupiedBy))\n" + text("替换后，该动作的原快捷键将被清空。", "Replacing clears the shortcut of the action above."))
            }
        }
        .onChange(of: navigation.current) { _, _ in shortcuts.cancel() }
        .onDisappear { shortcuts.cancel() }
    }
    /// macOS System Settings layout: a source list on the left, one grouped form at a time on the right.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(SettingsSection.allCases) { section in
                SettingsSidebarRow(
                    section: section,
                    title: section.title(english: english),
                    selected: navigation.current == section
                ) {
                    withAnimation(Design.Animation.snappy) {
                        navigation.navigate(to: section)
                    }
                }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 10).padding(.vertical, 12).frame(maxHeight: .infinity, alignment: .top)
            // The column stays transparent so both sides draw on the window's own glass (or one solid
            // plane in solid mode); the Divider is the only seam between them.
    }
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: navigation.current.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(navigation.current.tint.gradient, in: RoundedRectangle(cornerRadius: Design.Radius.badge + 1))
                    .shadow(color: navigation.current.tint.opacity(0.25), radius: 3, y: 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(navigation.current.title(english: english))
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(navigation.current.subtitle(english: english))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
            Group {
                switch navigation.current {
                case .general: general
                case .shortcuts: shortcutSettings
                case .translation: TranslationConfigurationView(configuration: translation, languagePacks: languagePacks)
                case .clipboard: ClipboardFeatureSettingsView(feature: clipboard)
                case .permissions: PermissionsSettingsView(status: permissionStatus, actions: actions)
                case .about: about
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            .id(navigation.current)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var general: some View {
        Form {
            Section {
                Picker(text("语言", "Language"), selection: Binding(get: { preferences.value.language }, set: actions.setLanguage)) {
                    Text(text("跟随系统", "System")).tag(Language.system)
                    Text("简体中文").tag(Language.simplifiedChinese)
                    Text("English").tag(Language.english)
                }
                Picker(text("外观", "Appearance"), selection: Binding(get: { preferences.value.appearance }, set: actions.setAppearance)) {
                    Text(text("系统", "System")).tag(Appearance.system)
                    Text(text("浅色", "Light")).tag(Appearance.light)
                    Text(text("深色", "Dark")).tag(Appearance.dark)
                }.pickerStyle(.segmented)
                Toggle(text("玻璃效果", "Glass effects"), isOn: Binding(get: { preferences.value.glassEnabled }, set: actions.setGlass))
            } footer: {
                Text(text("关闭玻璃效果，或开启系统“减少透明度 / 增强对比度”时，将自动回退为实底窗口。",
                         "Solid backgrounds are used automatically when Glass effects are off or when Reduce Transparency or Increase Contrast is enabled."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if preferences.failure != nil || actions.issue != nil {
                Section {
                    if let failure = preferences.failure {
                        Label(L(failure), systemImage: "exclamationmark.triangle")
                        Button(text("备份并恢复默认…", "Back up and restore defaults…")) { confirmPreferenceRecovery = true }
                    }
                    if let issue = actions.issue { Label(L(issue), systemImage: "exclamationmark.triangle") }
                }
            }
        }
        .toggleStyle(.switch)
        .alert(text("恢复新版本默认设置？", "Restore new-version defaults?"), isPresented: $confirmPreferenceRecovery) {
            Button(text("取消", "Cancel"), role: .cancel) {}
            Button(text("备份并恢复默认", "Back up and restore defaults"), role: .destructive) { actions.recoverPreferences(shortcuts: shortcuts) }
        } message: {
            Text(text("先备份损坏的文件，再恢复语言、外观和快捷键。其他数据不受影响。", "The damaged file is backed up first, then language, appearance and shortcuts are reset. Other data is unaffected."))
        }
    }
    private var shortcutSettings: some View {
        Form {
            Section {
                ForEach(Action.allCases, id: \.self) { action in
                    let chord = preferences.value.shortcuts.first(where: { $0.action == action })?.chord
                    let recording = shortcuts.recordingAction == action
                    LabeledContent(actionTitle(action)) {
                        HStack(spacing: 6) {
                            Button { shortcuts.begin(action) } label: {
                                Text(recording ? text("请按组合键…", "Press shortcut…") : chord?.display ?? text("未设置", "Not set"))
                                    .monospaced().foregroundStyle(recording ? Color.accentColor : (chord == nil ? .secondary : .primary))
                                    .frame(minWidth: 102).padding(.horizontal, 10).frame(height: 26)
                                    .background(recording ? Color.accentColor.opacity(0.12) : Color(nsColor: .quaternarySystemFill),
                                                in: RoundedRectangle(cornerRadius: Design.Radius.control))
                                    .overlay(RoundedRectangle(cornerRadius: Design.Radius.control)
                                        .stroke(recording ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.35), lineWidth: recording ? 2 : 0.5))
                            }.buttonStyle(.plain).help(text("录入快捷键；Esc 取消", "Record shortcut; Escape cancels"))
                                .accessibilityLabel(actionTitle(action) + text("快捷键", " shortcut"))
                            Button { shortcuts.clear(action) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                .buttonStyle(.borderless).help(text("清空", "Clear") + " " + actionTitle(action))
                                .accessibilityLabel(text("清空", "Clear") + " " + actionTitle(action))
                                .disabled(chord == nil).opacity(chord == nil ? 0 : 1)
                        }
                    }
                }
            } footer: {
                Text(text("单击快捷键按钮录入组合键，按 Esc 取消。", "Click a shortcut button to record a key combination; press Esc to cancel."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = shortcuts.message {
                Section { Label(L(message), systemImage: shortcuts.recordingAction == nil ? "exclamationmark.triangle" : "keyboard").textSelection(.enabled) }
            }
            Section {
                HStack {
                    Button(text("恢复默认", "Restore Defaults")) { shortcuts.restoreDefaults() }
                    if shortcuts.recordingAction != nil { Button(text("取消录入", "Cancel Recording")) { shortcuts.cancel() } }
                }
            }
        }
    }
    private func actionTitle(_ action: Action) -> String {
        guard english else { return action.title }
        switch action { case .regionCapture: return "Region capture"; case .screenCapture: return "Screen capture"; case .inputTranslation: return "Input translation"; case .captureTranslation: return "Capture translation"; case .clipboard: return "Clipboard" }
    }
    private var about: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    BrandIcon(size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Traylet").font(.headline)
                        Text(text("轻巧本机运行的 macOS 菜单栏工具", "Lightweight on-device macOS menu bar utility"))
                            .font(.caption).foregroundStyle(.secondary)
                        StatusPill(text: version, tint: .accentColor)
                    }
                }.padding(.vertical, 6)
            }
            Section {
                Toggle(text("自动检查更新", "Check for updates automatically"),
                       isOn: Binding(get: { preferences.value.autoCheckUpdates }, set: actions.setAutoCheckUpdates))
                Toggle(text("包含开源预览版", "Include open-source preview releases"),
                       isOn: Binding(get: { preferences.value.includePreviewUpdates }, set: actions.setIncludePreviewUpdates))
                updateStatusRow
            } header: {
                Text(text("软件更新", "Software Updates"))
            } footer: {
                Text(text("仅从 GitHub Releases (api.github.com) 只读查询版本信息与校验文件，不上传任何本机数据。",
                          "Queries GitHub Releases (api.github.com) read-only for version metadata and checksums. No local data is uploaded."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup(text("第三方声明", "Third-party notices")) {
                    Text(text("仅使用 Apple 系统框架，无第三方付费依赖。", "Uses Apple system frameworks only. No paid third-party dependencies."))
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var updateStatusRow: some View {
        switch updater.state {
        case .idle:
            HStack {
                Text(text("通过 GitHub Releases 获取更新", "Check for updates via GitHub Releases"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(text("检查更新", "Check for Updates")) {
                    Task { await updater.checkForUpdates(manual: true) }
                }
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text("正在检查 GitHub Releases…", "Checking GitHub Releases…"))
                    .foregroundStyle(.secondary)
            }
        case .upToDate:
            HStack {
                Label(text("已是最新版本", "You're up to date"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(text("检查更新", "Check for Updates")) {
                    Task { await updater.checkForUpdates(manual: true) }
                }
            }
        case .available(let release):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(text("发现新版本", "Update available") + ": \(release.displayVersion)", systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                if !release.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(release.releaseNotes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                HStack(spacing: 8) {
                    if release.downloadURL != nil && release.sha256URL != nil {
                        Button(text("下载并校验", "Download & Verify")) {
                            Task { await updater.downloadUpdate() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button(text("在 GitHub 查看", "View on GitHub")) {
                        updater.openReleasePage(release)
                    }
                    Button(text("跳过此版本", "Skip This Version")) {
                        updater.skipVersion(release)
                    }
                }
            }
            .padding(.vertical, 4)
        case .downloading(let release):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text("正在下载并校验 SHA-256…", "Downloading and verifying SHA-256…") + " (\(release.displayVersion))")
                    .foregroundStyle(.secondary)
            }
        case .readyToInstall(let release, _, let canReplaceInPlace):
            VStack(alignment: .leading, spacing: 8) {
                Label(text("SHA-256 校验通过", "SHA-256 verified") + " (\(release.displayVersion))", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
                Text(text("未公证的开源预览包若首次被系统拦截，可右键应用选择「打开」。",
                          "If macOS blocks an unnotarized open-source preview build on first launch, Control-click the app and choose Open."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if canReplaceInPlace {
                        Button(text("替换并重启", "Install and Relaunch")) {
                            updater.installStagedUpdate(requestQuit: onRequestQuitForUpdate)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(text("在访达中显示", "Reveal in Finder")) {
                            updater.installStagedUpdate(requestQuit: onRequestQuitForUpdate)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button(text("在 GitHub 查看", "View on GitHub")) {
                        updater.openReleasePage(release)
                    }
                }
            }
            .padding(.vertical, 4)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(L(message), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button(text("重试", "Retry")) {
                    Task { await updater.checkForUpdates(manual: true) }
                }
            }
        }
    }
    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "TrayletReleaseVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? text("开发版", "Development")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(text("构建", "build")) \(build))"
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(section.tint.gradient, in: RoundedRectangle(cornerRadius: Design.Radius.badge))
                    .shadow(color: section.tint.opacity(0.24), radius: 2, y: 1)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.body.weight(selected ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                selected ? AnyShapeStyle(Color.accentColor)
                         : AnyShapeStyle(hovering ? Color.primary.opacity(0.06) : Color.clear),
                in: RoundedRectangle(cornerRadius: Design.Radius.control)
            )
            // The whole row is the target, not just the glyph and title.
            .contentShape(RoundedRectangle(cornerRadius: Design.Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
