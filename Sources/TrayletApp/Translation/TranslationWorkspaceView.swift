import SwiftUI
import UniformTypeIdentifiers
import TrayletCore

struct TranslationWorkspaceView: View {
    @ObservedObject var controller: TranslationController
    @ObservedObject var flow: TranslationFlow
    @ObservedObject var configuration: TranslationConfiguration
    @ObservedObject private var localization = Localization.shared
    @FocusState private var inputFocused: Bool
    static let languages = [("auto", "自动检测"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어"), ("fr", "Français"), ("de", "Deutsch"), ("es", "Español"), ("it", "Italiano"), ("pt", "Português"), ("ru", "Русский"), ("ar", "العربية"), ("hi", "हिन्दी"), ("vi", "Tiếng Việt"), ("th", "ไทย"), ("id", "Bahasa Indonesia"), ("tr", "Türkçe"), ("pl", "Polski"), ("uk", "Українська"), ("nl", "Nederlands")]
    var body: some View {
        VStack(spacing: Design.Space.s) {
            controlRow
            textBox(input: true)
            textBox(input: false)
        }
        .padding(.horizontal, Design.Space.m).padding(.top, Design.Space.m).padding(.bottom, Design.Space.s)
        .background { if let work = controller.systemWork { TranslationSystemTaskHost(work: work, prepare: controller.preparingResources, completed: controller.finishSystem, failed: controller.failSystem).id(work.id) } }
        .onDisappear { controller.cancel() }
    }
    /// One row of same-height glass controls: languages on the left, engines and settings on the right.
    private var controlRow: some View {
        HStack(spacing: 6) {
            languageMenu("原文语言", selection: $flow.source, includeAuto: true)
            WorkspaceIconButton(
                symbol: "arrow.left.arrow.right",
                label: "互换语言",
                iconSize: 12,
                disabled: flow.source == "auto"
            ) {
                flow.swapLanguages()
            }
            .v2GlassBackground(in: Circle(), interactive: true)
            languageMenu("译文语言", selection: $flow.target, includeAuto: false)
            Spacer(minLength: 4)
            engineIcons
            WorkspaceIconButton(
                symbol: "text.viewfinder",
                label: controller.lastSourceImage != nil ? "在 OCR 窗口查看原图" : "截图 OCR 识别"
            ) {
                controller.openOCR()
            }
            .v2GlassBackground(in: Circle(), interactive: true)
            WorkspaceIconButton(symbol: "gearshape", label: "设置") {
                controller.openLanguageSettings()
            }
            .v2GlassBackground(in: Circle(), interactive: true)
        }
    }
    private func textBox(input: Bool) -> some View {
        let text = input ? flow.input : flow.output
        let speaking = controller.speakingSource == input
        let focused = input && inputFocused
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L(input ? "原文" : "译文"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if !input, !flow.output.isEmpty, !flow.outputIsCurrent {
                    StatusPill(text: L("内容已变更"), tint: .orange)
                }
                // Screenshot text recognition runs on the source, so its progress is shown here.
                if input, flow.phase == .recognizing { ProgressView().controlSize(.mini); Text(L("正在本机识别截图文字…")).font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                if input, !flow.input.isEmpty {
                    Text(String(format: L("%d 字符"), flow.input.count))
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                } else if !input {
                    StatusPill(text: L(Self.engineTitle(controller.selectedEngine)), tint: .accentColor)
                }
            }
            if input, controller.accessibilityNotice {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    Text(L("无法读取选中文本：请在系统设置中允许 Traylet 使用辅助功能，然后重新打开 Traylet。")).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(L("打开系统设置")) { controller.openAccessibilitySettings() }.controlSize(.small)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Design.Radius.control))
            }
            if input {
                TextEditor(text: $flow.input).font(.body).scrollContentBackground(.hidden).focused($inputFocused).accessibilityLabel(L("原文输入"))
                    // TextEditor insets its text by 5pt; pull it back so it lines up with the caption above.
                    .padding(.horizontal, -5).padding(.bottom, 38)
                    .onDrop(of: [.fileURL, .image, .png], isTargeted: nil) { providers in
                        for provider in providers {
                            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                                    guard let data = item as? Data,
                                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                                    Task { @MainActor in controller.handleDroppedImage(from: url) }
                                }
                                return true
                            }
                            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                                    guard let data else { return }
                                    Task { @MainActor in controller.handleDroppedImageData(data) }
                                }
                                return true
                            }
                        }
                        return false
                    }
            } else {
                ScrollView { VStack(alignment: .leading, spacing: 12) { status; if !controller.notice.isEmpty { Text(L(controller.notice)).font(.caption).textSelection(.enabled) }; Text(flow.output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 38)
            }
        }
        .padding(Design.Space.m).frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
        // Floating glass action capsules: speak/copy at bottom-left (with detected language), clear + translate at bottom-right.
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 4) {
                HStack(spacing: 2) {
                    WorkspaceIconButton(
                        symbol: speaking ? "stop.fill" : "speaker.wave.2",
                        label: speaking ? "停止朗读" : (input ? "朗读原文" : "朗读译文"),
                        disabled: text.isEmpty && !speaking
                    ) {
                        controller.toggleSpeaking(text, language: input ? flow.source : flow.target, source: input)
                    }
                    CopyIconButton(label: input ? "复制原文" : "复制译文", disabled: text.isEmpty) {
                        controller.copy(text)
                    }
                }
                .padding(.horizontal, 3)
                .v2GlassBackground(in: Capsule(), interactive: true)
                if input, let detected = flow.detectedLanguage, flow.source == "auto" {
                    StatusPill(
                        text: String(format: L("识别为：%@"), L(Self.languages.first { $0.0 == detected }?.1 ?? detected)),
                        tint: .secondary
                    )
                }
            }.padding(10)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 6) {
                if !input, flow.active != nil || flow.phase == .recognizing {
                    Button(L("取消")) { controller.cancel() }.controlSize(.small)
                }
                WorkspaceIconButton(
                    symbol: "xmark.circle",
                    label: input ? "清空输入" : "清空译文",
                    disabled: text.isEmpty
                ) {
                    if input { flow.input = "" } else { controller.clearOutput() }
                }
                .v2GlassBackground(in: Circle(), interactive: true)
                if input {
                    let unavailable = flow.phase == .recognizing || !flow.hasTranslatableContent
                    Button { controller.startSubmission() } label: {
                        Text(L("翻译")).font(.callout.weight(.semibold)).foregroundStyle(.white).lineLimit(1).fixedSize()
                            .padding(.horizontal, 14).frame(height: Design.iconButton)
                            .background(Color.accentColor.gradient, in: Capsule())
                            .shadow(color: Color.accentColor.opacity(unavailable ? 0 : 0.25), radius: 4, y: 1)
                    }.buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command).disabled(unavailable).opacity(unavailable ? 0.4 : 1)
                        .help(L("翻译") + " ⌘↩")
                }
            }.padding(10)
        }
        .v2GlassBackground(in: RoundedRectangle(cornerRadius: Design.Radius.panel))
        .v2PanelFocusRing(focused: focused)
    }
    /// The menu label is the selected language only, so each control is as narrow as its current value.
    private func languageMenu(_ title: String, selection: Binding<String>, includeAuto: Bool) -> some View {
        let choices = Self.languages.filter { includeAuto || $0.0 != "auto" }
        return Menu {
            ForEach(choices, id: \.0) { choice in
                Button { selection.wrappedValue = choice.0 } label: {
                    if selection.wrappedValue == choice.0 { Label(L(choice.1), systemImage: "checkmark") } else { Text(L(choice.1)) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(L(choices.first { $0.0 == selection.wrappedValue }?.1 ?? selection.wrappedValue)).font(.callout).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).frame(height: Design.iconButton).contentShape(Capsule()).v2GlassBackground(in: Capsule(), interactive: true)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help(L(title)).accessibilityLabel(L(title))
    }
    static func engineTitle(_ engine: TranslationEngineChoice) -> String {
        switch engine { case .system: "系统翻译"; case .ai: "AI 翻译"; case .deepl: "DeepL 翻译"; case .google: "Google 翻译"; case .myMemory: "MyMemory 翻译" }
    }
    /// One icon per enabled engine inside a shared Liquid Glass capsule tray, default first.
    private var engineIcons: some View {
        HStack(spacing: 6) {
            ForEach(configuration.visibleEngines) { engine in
                let selected = controller.selectedEngine == engine
                Button {
                    withAnimation(Design.Animation.snappy) { controller.select(engine) }
                } label: {
                    TranslationEngineIcon(engine: engine, size: 15, tint: selected ? Color.accentColor : Color.primary)
                        .frame(width: Design.iconButton, height: Design.iconButton)
                        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: Circle())
                        .contentShape(Circle())
                        .overlay(Circle().strokeBorder(Color.accentColor.opacity(selected ? 0.8 : 0), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(flow.phase == .recognizing)
                .help(String(format: L("翻译引擎：%@"), L(Self.engineTitle(engine)))).accessibilityLabel(L(Self.engineTitle(engine)))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .v2GlassBackground(in: Capsule(), interactive: true)
        .fixedSize()
    }
    @ViewBuilder private var status: some View {
        switch flow.phase {
        case .idle: EmptyView()
        case .recognizing: EmptyView()
        case .translating: HStack { ProgressView().controlSize(.small); Text(L(controller.preparingResources ? "正在准备语言资源并翻译…" : "正在翻译…")) }
        case .resourceRequired:
            VStack(alignment: .leading, spacing: 6) {
                Label(L("系统语言资源尚未安装。"), systemImage: "arrow.down.circle")
                HStack(spacing: 8) {
                    Button(L("前往设置下载语言包")) { controller.openLanguageSettings() }
                        .controlSize(.small)
                    Button(L("直接准备并翻译")) { controller.prepareLanguages() }
                        .controlSize(.small)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(L(message), systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                if controller.canRetrySubmission {
                    Button(L("重试")) { controller.retrySubmission() }
                        .controlSize(.small)
                        .help(L("使用当前原文、语言和引擎重试"))
                        .accessibilityLabel(L("重试翻译"))
                }
            }
        }
    }
}
