import SwiftUI
import TrayletCore

struct TranslationWorkspaceView: View {
    @ObservedObject var controller: TranslationController
    @ObservedObject var flow: TranslationFlow
    @ObservedObject var configuration: TranslationConfiguration
    @ObservedObject private var localization = V2Localization.shared
    @FocusState private var inputFocused: Bool
    static let languages = [("auto", "自动检测"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어"), ("fr", "Français"), ("de", "Deutsch"), ("es", "Español"), ("it", "Italiano"), ("pt", "Português"), ("ru", "Русский"), ("ar", "العربية"), ("hi", "हिन्दी"), ("vi", "Tiếng Việt"), ("th", "ไทย"), ("id", "Bahasa Indonesia"), ("tr", "Türkçe"), ("pl", "Polski"), ("uk", "Українська"), ("nl", "Nederlands")]
    var body: some View {
        VStack(spacing: V2Design.Space.s) {
            textBox(input: true)
            controlRow
            textBox(input: false)
        }
        .padding(.horizontal, V2Design.Space.m).padding(.top, V2Design.Space.m).padding(.bottom, V2Design.Space.s)
        .background { if let work = controller.systemWork { TranslationSystemTaskHost(work: work, prepare: controller.preparingResources, completed: controller.finishSystem, failed: controller.failSystem).id(work.id) } }
        .sheet(item: Binding(get: { controller.preview }, set: { if $0 == nil, controller.flow.phase == .awaitingConfirmation { controller.cancel() } })) { request in
            TranslationSendPreview(request: request, cancel: controller.cancel) { controller.startConfirmed(request) }
        }
        .onDisappear { controller.cancel() }
    }
    /// One row of same-height glass controls: languages and Translate on the left, engines and settings on the right.
    private var controlRow: some View {
        HStack(spacing: 6) {
            languageMenu("原文语言", selection: $flow.source, includeAuto: true)
            Button { flow.swapLanguages() } label: {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 12, weight: .medium)).frame(width: V2Design.iconButton, height: V2Design.iconButton).contentShape(Circle())
            }.buttonStyle(.plain).disabled(flow.source == "auto").opacity(flow.source == "auto" ? 0.35 : 1)
                .help(V2L("互换语言")).accessibilityLabel(V2L("互换语言"))
            languageMenu("译文语言", selection: $flow.target, includeAuto: false)
            let unavailable = flow.phase == .recognizing || flow.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button { controller.startSubmission() } label: {
                Text(V2L("翻译")).font(.callout.weight(.medium)).foregroundStyle(.white).lineLimit(1).fixedSize()
                    .padding(.horizontal, 14).frame(height: V2Design.iconButton).background(Color.accentColor, in: Capsule())
            }.buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command).disabled(unavailable).opacity(unavailable ? 0.4 : 1)
            Spacer(minLength: 4)
            engineIcons
            Button { controller.openLanguageSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .medium)).frame(width: V2Design.iconButton, height: V2Design.iconButton).contentShape(Circle()).v2GlassBackground(in: Circle())
            }.buttonStyle(.plain).help(V2L("设置")).accessibilityLabel(V2L("设置"))
        }
    }
    private func textBox(input: Bool) -> some View {
        let text = input ? flow.input : flow.output
        let speaking = controller.speakingSource == input
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(V2L(input ? "原文" : (!flow.output.isEmpty && !flow.outputIsCurrent ? "上次译文（输入或翻译设置已变更）" : "译文"))).font(.caption).foregroundStyle(.secondary)
                // Screenshot text recognition runs on the source, so its progress is shown here.
                if input, flow.phase == .recognizing { ProgressView().controlSize(.mini); Text(V2L("正在本机识别截图文字…")).font(.caption).foregroundStyle(.secondary) }
            }
            if input, controller.accessibilityNotice {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    Text(V2L("无法读取选中文本：请在系统设置中允许 Traylet 使用辅助功能，然后重新打开 Traylet。")).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(V2L("打开系统设置")) { controller.openAccessibilitySettings() }.controlSize(.small)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            if input {
                TextEditor(text: $flow.input).font(.body).scrollContentBackground(.hidden).focused($inputFocused).accessibilityLabel(V2L("原文输入"))
                    // TextEditor insets its text by 5pt; pull it back so it lines up with the caption above.
                    .padding(.horizontal, -5).padding(.bottom, 28)
            } else {
                ScrollView { VStack(alignment: .leading, spacing: 12) { status; if !controller.notice.isEmpty { Text(V2L(controller.notice)).font(.caption).textSelection(.enabled) }; Text(flow.output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 28)
            }
        }
        .padding(V2Design.Space.m).frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
        // Floating icon buttons: speak/copy at bottom-left (with the detected language), clear at bottom-right; text scrolls above them.
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 2) {
                icon(speaking ? "stop.fill" : "speaker.wave.2", speaking ? "停止朗读" : (input ? "朗读原文" : "朗读译文")) {
                    controller.toggleSpeaking(text, language: input ? flow.source : flow.target, source: input)
                }.disabled(text.isEmpty && !speaking)
                icon("doc.on.doc", input ? "复制原文" : "复制译文") { controller.copy(text) }.disabled(text.isEmpty)
                if input, let detected = flow.detectedLanguage, flow.source == "auto" {
                    Text(String(format: V2L("识别为：%@"), V2L(Self.languages.first { $0.0 == detected }?.1 ?? detected))).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).padding(.leading, 4)
                }
            }.padding(6)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 4) {
                if !input, flow.active != nil || flow.phase == .recognizing { Button(V2L("取消")) { controller.cancel() }.controlSize(.small) }
                icon("xmark.circle", input ? "清空输入" : "清空译文") { if input { flow.input = "" } else { controller.clearOutput() } }
            }.padding(6)
        }
        .v2GlassBackground(in: RoundedRectangle(cornerRadius: V2Design.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: V2Design.Radius.panel).strokeBorder(Color.accentColor, lineWidth: input && inputFocused ? 3 : 0))
    }
    /// The menu label is the selected language only, so each control is as narrow as its current value.
    private func languageMenu(_ title: String, selection: Binding<String>, includeAuto: Bool) -> some View {
        let choices = Self.languages.filter { includeAuto || $0.0 != "auto" }
        return Menu {
            ForEach(choices, id: \.0) { choice in
                Button { selection.wrappedValue = choice.0 } label: {
                    if selection.wrappedValue == choice.0 { Label(V2L(choice.1), systemImage: "checkmark") } else { Text(V2L(choice.1)) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(V2L(choices.first { $0.0 == selection.wrappedValue }?.1 ?? selection.wrappedValue)).font(.callout).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).frame(height: V2Design.iconButton).contentShape(Capsule()).v2GlassBackground(in: Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help(V2L(title)).accessibilityLabel(V2L(title))
    }
    static func engineTitle(_ engine: TranslationEngineChoice) -> String {
        switch engine { case .system: "系统翻译"; case .ai: "AI 翻译"; case .deepl: "DeepL 翻译"; case .google: "Google 翻译"; case .myMemory: "MyMemory 翻译" }
    }
    /// One icon per enabled engine, default first; choosing one translates the current source text with it.
    private var engineIcons: some View {
        HStack(spacing: 6) {
            ForEach(configuration.visibleEngines) { engine in
                let selected = controller.selectedEngine == engine
                Button { controller.select(engine) } label: {
                    TranslationEngineIcon(engine: engine, size: 16, tint: selected ? Color.accentColor : Color.primary)
                        .frame(width: V2Design.iconButton, height: V2Design.iconButton)
                        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: Circle())
                        .contentShape(Circle()).v2GlassBackground(in: Circle())
                        .overlay(Circle().strokeBorder(Color.accentColor.opacity(selected ? 0.9 : 0), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(flow.phase == .recognizing)
                .help(String(format: V2L("翻译引擎：%@"), V2L(Self.engineTitle(engine)))).accessibilityLabel(V2L(Self.engineTitle(engine)))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.fixedSize()
    }
    @ViewBuilder private var status: some View {
        switch flow.phase {
        case .idle: EmptyView()
        case .recognizing: EmptyView()
        case .awaitingConfirmation: Label(V2L("等待确认发送正文。"), systemImage: "checkmark.shield")
        case .translating: HStack { ProgressView().controlSize(.small); Text(V2L(controller.preparingResources ? "正在准备语言资源并翻译…" : "正在翻译…")) }
        case .resourceRequired:
            VStack(alignment: .leading, spacing: 6) {
                Label(V2L("系统语言资源尚未安装。"), systemImage: "arrow.down.circle")
                HStack(spacing: 8) {
                    Button(V2L("前往设置下载语言包")) { controller.openLanguageSettings() }
                        .controlSize(.small)
                    Button(V2L("直接准备并翻译")) { controller.prepareLanguages() }
                        .controlSize(.small)
                }
                Text(V2L("建议先在设置中提前下载语言包；下载完成后返回翻译窗口重试。自动检测时请先选择明确的原文语言。")).font(.caption)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(V2L(message), systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                if controller.canRetrySubmission {
                    Button(V2L("重试")) { controller.retrySubmission() }
                        .controlSize(.small)
                        .help(V2L("使用当前原文、语言和引擎重试"))
                        .accessibilityLabel(V2L("重试翻译"))
                }
            }
        }
    }
    private func icon(_ name: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 13, weight: .regular)).frame(width: V2Design.iconButton, height: V2Design.iconButton).contentShape(Circle()) }.buttonStyle(.plain).help(V2L(label)).accessibilityLabel(V2L(label))
    }
}

struct TranslationSendPreview: View {
    @ObservedObject private var localization = V2Localization.shared
    let request: TranslationAIRequest
    let cancel: () -> Void
    let send: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(V2L(request.action != .models && request.action != .connection ? "确认发送翻译正文" : "确认访问 AI 服务")).font(.headline)
            Text(String(format: V2L("目标：%@"), request.destination)).textSelection(.enabled)
            Text(V2L(request.settings.credential.isEmpty ? "不携带 API Key。" : "将向此目标携带当前内存中的 API Key（隐藏）。")).font(.caption)
            if request.action == .models || request.action == .connection { Text(V2L("GET 请求获取模型列表；不包含原文、截图或剪贴板。")) }
            else if request.action == .deeplTranslate || request.action == .googleTranslate || request.action == .myMemoryTranslate {
                Text(V2L(request.action == .deeplTranslate ? "服务：DeepL 官方 API，仅发送下列文本与语言代码，并携带内存中的 API Key（隐藏）。" : "服务：免费翻译服务，仅发送下列文本与语言代码；不携带账号或密钥。本窗口内再次使用该引擎将直接发送，关闭窗口后重新确认。"))
                Text(String(format: V2L("方向：%@ → %@"), request.source, request.target))
                ScrollView { Text(request.content).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(minHeight: 100, maxHeight: 250)
            } else {
                Text(String(format: V2L("模型：%@"), request.settings.model))
                Text(String(format: V2L("方向：%@ → %@"), request.source, request.target))
                Text(String(format: V2L("系统指令：%@"), request.instruction)).font(.caption).textSelection(.enabled)
                ScrollView { Text(request.content).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(minHeight: 100, maxHeight: 250)
            }
            HStack { Spacer(); Button(V2L("取消"), action: cancel).keyboardShortcut(.cancelAction); Button(V2L("发送"), action: send).buttonStyle(.borderedProminent) }
        }.padding(20).frame(width: 500)
    }
}
