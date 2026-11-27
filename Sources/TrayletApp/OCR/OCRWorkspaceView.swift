import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct OCRWorkspaceView: View {
    @ObservedObject var controller: OCRController
    @ObservedObject private var localization = Localization.shared
    @FocusState private var editorFocused: Bool
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: Design.Space.s) {
            if controller.showsPreview {
                previewPane
                    .frame(minWidth: 220, idealWidth: 320, maxWidth: 420)
            }
            resultPane
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, Design.Space.m)
        .padding(.top, Design.Space.m)
        .padding(.bottom, Design.Space.s)
        .background {
            Button {
                if !controller.text.isEmpty && controller.phase != .recognizing {
                    controller.copyText()
                }
            } label: { EmptyView() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onDisappear { controller.cancel() }
    }

    private var previewPane: some View {
        VStack(spacing: Design.Space.xs) {
            HStack(spacing: 2) {
                WorkspaceIconButton(symbol: "minus.magnifyingglass", label: "缩小", size: 26, iconSize: 12, disabled: controller.previewImage == nil) {
                    controller.zoomScale = max(0.25, controller.zoomScale - 0.25)
                }

                Button { controller.zoomScale = 1.0 } label: {
                    Text("\(Int((controller.zoomScale * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 38).frame(height: 22)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(controller.previewImage == nil)
                .help(L("重置视图"))

                WorkspaceIconButton(symbol: "plus.magnifyingglass", label: "放大", size: 26, iconSize: 12, disabled: controller.previewImage == nil) {
                    controller.zoomScale = min(4.0, controller.zoomScale + 0.25)
                }

                WorkspaceIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "重置视图", size: 26, iconSize: 11, disabled: controller.previewImage == nil) {
                    controller.zoomScale = 1.0
                }

                Spacer(minLength: 4)

                WorkspaceIconButton(symbol: "camera.viewfinder", label: "重新截图", size: 26, iconSize: 12) {
                    controller.recapture()
                }

                WorkspaceIconButton(symbol: "photo.badge.plus", label: "导入图片", size: 26, iconSize: 12) {
                    chooseImageFile()
                }

                WorkspaceIconButton(symbol: "sidebar.left", label: "收起原图", size: 26, iconSize: 12) {
                    withAnimation(Design.Animation.snappy) { controller.showsPreview = false }
                }
            }
            .padding(.horizontal, 6)
            .frame(height: Design.iconButton)
            .v2GlassBackground(in: Capsule(), interactive: true)

            ZStack {
                if let nsImage = controller.previewImage {
                    GeometryReader { geo in
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(
                                    width: max(geo.size.width - 16, 120) * controller.zoomScale,
                                    height: max(geo.size.height - 16, 120) * controller.zoomScale
                                )
                                .padding(8)
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text(L("拖入或选择图片"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button(L("截图识别")) { controller.recapture() }
                                .controlSize(.small)
                            Button(L("选择图片")) { chooseImageFile() }
                                .controlSize(.small)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .v2GlassBackground(in: RoundedRectangle(cornerRadius: Design.Radius.panel))
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.panel)
                    .strokeBorder(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .onDrop(of: [.fileURL, .image, .png], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
        }
    }

    private var resultPane: some View {
        VStack(spacing: Design.Space.xs) {
            topControlRow
            textResultBox
        }
    }

    private var topControlRow: some View {
        HStack(spacing: 6) {
            if !controller.showsPreview {
                WorkspaceIconButton(symbol: "sidebar.left", label: "展开原图") {
                    withAnimation(Design.Animation.snappy) { controller.showsPreview = true }
                }
                .v2GlassBackground(in: Circle(), interactive: true)
            }

            Picker("", selection: Binding(
                get: { controller.selectedEngine },
                set: { controller.selectEngine($0) }
            )) {
                ForEach(OCREngineChoice.allCases) { engine in
                    Text(L(engine.title)).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if controller.selectedEngine == .ai {
                Menu {
                    ForEach(OCRAIPreset.allCases) { preset in
                        Button {
                            controller.selectPreset(preset)
                        } label: {
                            if controller.selectedPreset == preset {
                                Label(L(preset.title), systemImage: "checkmark")
                            } else {
                                Text(L(preset.title))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(L(controller.selectedPreset.title))
                            .font(.callout)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: Design.iconButton)
                    .v2GlassBackground(in: Capsule(), interactive: true)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("识别模式"))
            }

            Spacer(minLength: 4)

            WorkspaceIconButton(
                symbol: "arrow.clockwise",
                label: "重新识别",
                help: L("重新识别") + " ⌘R",
                disabled: controller.image == nil || controller.phase == .recognizing
            ) {
                controller.recognize()
            }
            .keyboardShortcut("r", modifiers: .command)
            .v2GlassBackground(in: Circle(), interactive: true)

            WorkspaceIconButton(symbol: "gearshape", label: "设置") {
                controller.openSettings()
            }
            .v2GlassBackground(in: Circle(), interactive: true)
        }
    }

    private var textResultBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("识别结果"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if controller.phase == .recognizing {
                    ProgressView().controlSize(.mini)
                    Text(L(controller.selectedEngine == .vision ? "正在本机识别文字…" : "正在通过 AI 识别…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !controller.text.isEmpty {
                    Text(String(format: L("%d 字符"), controller.text.count))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                StatusPill(text: L(controller.selectedEngine.title), tint: .accentColor)
            }

            if case .failed(let message) = controller.phase {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(L(message))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if controller.image != nil {
                        Button(L("重试")) { controller.recognize() }
                            .controlSize(.small)
                    }
                    if controller.selectedEngine == .ai {
                        Button(L("前往设置")) { controller.openSettings() }
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Design.Radius.control))
            }

            if !controller.notice.isEmpty {
                Text(L(controller.notice))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            TextEditor(text: $controller.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .accessibilityLabel(L("识别结果"))
                .padding(.horizontal, -5)
                .padding(.bottom, 38)
        }
        .padding(Design.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 2) {
                WorkspaceIconButton(
                    symbol: controller.speaking ? "stop.fill" : "speaker.wave.2",
                    label: controller.speaking ? "停止朗读" : "朗读",
                    disabled: controller.text.isEmpty && !controller.speaking
                ) {
                    controller.toggleSpeaking()
                }

                CopyIconButton(label: "复制", disabled: controller.text.isEmpty) {
                    controller.copyText()
                }

                WorkspaceIconButton(
                    symbol: "text.alignleft",
                    label: "合并换行",
                    disabled: controller.text.isEmpty
                ) {
                    controller.applyMergeLineBreaks()
                }
            }
            .padding(.horizontal, 3)
            .v2GlassBackground(in: Capsule(), interactive: true)
            .padding(8)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 6) {
                if controller.phase == .recognizing {
                    Button(L("取消")) { controller.cancel() }
                        .controlSize(.small)
                }
                WorkspaceIconButton(
                    symbol: "xmark.circle",
                    label: "清空",
                    disabled: controller.text.isEmpty && controller.phase != .recognizing
                ) {
                    controller.clear()
                }
                .v2GlassBackground(in: Circle(), interactive: true)

                let canTranslate = !controller.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && controller.phase != .recognizing
                Button { controller.sendToTranslation() } label: {
                    Text(L("去翻译"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 14)
                        .frame(height: Design.iconButton)
                        .background(Color.accentColor.gradient, in: Capsule())
                        .shadow(color: Color.accentColor.opacity(canTranslate ? 0.25 : 0), radius: 4, y: 1)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canTranslate)
                .opacity(canTranslate ? 1 : 0.4)
                .help(L("去翻译") + " ⌘↩")
            }
            .padding(8)
        }
        .v2GlassBackground(in: RoundedRectangle(cornerRadius: Design.Radius.panel))
        .v2PanelFocusRing(focused: editorFocused)
    }

    private func chooseImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            controller.importImage(from: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in controller.importImage(from: url) }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in controller.importImageData(data) }
                }
                return true
            }
        }
        return false
    }
}
