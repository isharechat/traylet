import AppKit
import SwiftUI

@MainActor struct V2SettingsWorkspaceView: View {
    @ObservedObject var preferences: V2PreferencesStore
    @ObservedObject var shortcuts: V2ShortcutManager
    @ObservedObject var translation: TranslationConfiguration
    let languagePacks: TranslationLanguagePackController
    let clipboard: ClipboardFeature
    @ObservedObject var navigation: V2SettingsNavigation
    @ObservedObject var actions: V2SettingsActions
    @ObservedObject var localization: V2Localization = .shared
    @ObservedObject private var appearance = V2AppearanceState.shared
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
        .background(V2ShortcutRecordingResponder(manager: shortcuts).frame(width: 0, height: 0))
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
        VStack(alignment: .leading, spacing: 2) {
            ForEach(V2SettingsSection.allCases) { section in
                let selected = navigation.current == section
                Button { navigation.navigate(to: section) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: section.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20).background(section.tint.gradient, in: RoundedRectangle(cornerRadius: 5)).accessibilityHidden(true)
                        Text(section.title(english: english)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(height: 30).frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: V2Design.Radius.control - 2))
                    // The whole row is the target, not just the glyph and title.
                    .contentShape(RoundedRectangle(cornerRadius: V2Design.Radius.control - 2))
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 10).padding(.vertical, 12).frame(maxHeight: .infinity, alignment: .top)
            // The column stays transparent so both sides draw on the window's own glass (or one solid
            // plane in solid mode); the Divider is the only seam between them.
    }
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(navigation.current.title(english: english)).font(.title3.weight(.semibold))
                .padding(.horizontal, 20).padding(.top, 16).accessibilityAddTraits(.isHeader)
            Group {
                switch navigation.current {
                case .general: general
                case .shortcuts: shortcutSettings
                case .translation: TranslationConfigurationView(configuration: translation, languagePacks: languagePacks)
                case .clipboard: ClipboardFeatureSettingsView(feature: clipboard)
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
                    Text(text("跟随系统", "System")).tag(V2Language.system)
                    Text("简体中文").tag(V2Language.simplifiedChinese)
                    Text("English").tag(V2Language.english)
                }
                Picker(text("外观", "Appearance"), selection: Binding(get: { preferences.value.appearance }, set: actions.setAppearance)) {
                    Text(text("系统", "System")).tag(V2Appearance.system)
                    Text(text("浅色", "Light")).tag(V2Appearance.light)
                    Text(text("深色", "Dark")).tag(V2Appearance.dark)
                }.pickerStyle(.segmented)
                Toggle(text("玻璃效果", "Glass effects"), isOn: Binding(get: { preferences.value.glassEnabled }, set: actions.setGlass))
            }
            Section {
                Toggle(text("登录时启动", "Open at login"), isOn: Binding(get: { actions.loginEnabled }, set: actions.setLoginEnabled))
                if actions.loginRequiresApproval {
                    Label(text("需在系统设置 → 通用 → 登录项中批准", "Approve in System Settings → General → Login Items"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            if preferences.failure != nil || actions.issue != nil {
                Section {
                    if let failure = preferences.failure {
                        Label(V2L(failure), systemImage: "exclamationmark.triangle")
                        Button(text("备份并恢复默认…", "Back up and restore defaults…")) { confirmPreferenceRecovery = true }
                    }
                    if let issue = actions.issue { Label(V2L(issue), systemImage: "exclamationmark.triangle") }
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
                ForEach(V2Action.allCases, id: \.self) { action in
                    let chord = preferences.value.shortcuts.first(where: { $0.action == action })?.chord
                    let recording = shortcuts.recordingAction == action
                    LabeledContent(actionTitle(action)) {
                        HStack(spacing: 6) {
                            Button { shortcuts.begin(action) } label: {
                                Text(recording ? text("请按组合键…", "Press shortcut…") : chord?.display ?? text("未设置", "Not set"))
                                    .monospaced().foregroundStyle(chord == nil && !recording ? .secondary : .primary)
                                    .frame(minWidth: 96).padding(.horizontal, 10).frame(height: 24)
                                    .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(recording ? Color.accentColor : .clear, lineWidth: 2))
                            }.buttonStyle(.plain).help(text("录入快捷键；Esc 取消", "Record shortcut; Escape cancels"))
                                .accessibilityLabel(actionTitle(action) + text("快捷键", " shortcut"))
                            Button { shortcuts.clear(action) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                .buttonStyle(.borderless).help(text("清空", "Clear") + " " + actionTitle(action))
                                .accessibilityLabel(text("清空", "Clear") + " " + actionTitle(action))
                                .disabled(chord == nil).opacity(chord == nil ? 0 : 1)
                        }
                    }
                }
            }
            if let message = shortcuts.message {
                Section { Label(V2L(message), systemImage: shortcuts.recordingAction == nil ? "exclamationmark.triangle" : "keyboard").textSelection(.enabled) }
            }
            Section {
                HStack {
                    Button(text("恢复默认", "Restore Defaults")) { shortcuts.restoreDefaults() }
                    if shortcuts.recordingAction != nil { Button(text("取消录入", "Cancel Recording")) { shortcuts.cancel() } }
                }
            }
        }
    }
    private func actionTitle(_ action: V2Action) -> String {
        guard english else { return action.title }
        switch action { case .regionCapture: return "Region capture"; case .screenCapture: return "Screen capture"; case .inputTranslation: return "Input translation"; case .captureTranslation: return "Capture translation"; case .clipboard: return "Clipboard" }
    }
    private var about: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    V2BrandIcon(size: 48)
                    VStack(alignment: .leading, spacing: 2) { Text("Traylet").font(.headline); Text(version).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                }.padding(.vertical, 4)
            }
            Section {
                DisclosureGroup(text("第三方声明", "Third-party notices")) {
                    Text(text("仅使用 Apple 系统框架，无第三方付费依赖。", "Uses Apple system frameworks only. No paid third-party dependencies."))
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
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
