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
        .onDisappear { controller.cancel() }
    }

    private var previewPane: some View {
        VStack(spacing: Design.Space.xs) {
            HStack(spacing: 4) {
                Button { controller.zoomScale = max(0.25, controller.zoomScale - 0.25) } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .disabled(controller.previewImage == nil)
                .help(L("缩小"))

                Text("\(Int((controller.zoomScale * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 38)

                Button { controller.zoomScale = min(4.0, controller.zoomScale + 0.25) } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .disabled(controller.previewImage == nil)
                .help(L("放大"))

                Button { controller.zoomScale = 1.0 } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .disabled(controller.previewImage == nil)
                .help(L("重置视图"))

                Spacer(minLength: 4)

                Button { controller.recapture() } label: {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help(L("重新截图"))

                Button { chooseImageFile() } label: {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help(L("导入图片"))

                Button {
                    withAnimation(Design.Animation.snappy) { controller.showsPreview = false }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help(L("收起原图"))
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
                        Text(L("拖入图片或点击上方按钮导入"))
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
                Button {
                    withAnimation(Design.Animation.snappy) { controller.showsPreview = true }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: Design.iconButton, height: Design.iconButton)
                        .contentShape(Circle())
                        .v2GlassBackground(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .help(L("展开原图"))
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

            Button { controller.recognize() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: Design.iconButton, height: Design.iconButton)
                    .contentShape(Circle())
                    .v2GlassBackground(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .disabled(controller.image == nil || controller.phase == .recognizing)
            .help(L("重新识别"))

            Button { controller.openSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: Design.iconButton, height: Design.iconButton)
                    .contentShape(Circle())
                    .v2GlassBackground(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .help(L("设置"))
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
                capsuleIcon(controller.speaking ? "stop.fill" : "speaker.wave.2",
                            controller.speaking ? "停止朗读" : "朗读") {
                    controller.toggleSpeaking()
                }
                .disabled(controller.text.isEmpty && !controller.speaking)

                capsuleIcon("doc.on.doc", "复制") {
                    controller.copyText()
                }
                .disabled(controller.text.isEmpty)

                capsuleIcon("text.alignleft", "合并换行") {
                    controller.applyMergeLineBreaks()
                }
                .disabled(controller.text.isEmpty)
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
                capsuleIcon("xmark.circle", "清空") {
                    controller.clear()
                }
                .v2GlassBackground(in: Circle(), interactive: true)
                .disabled(controller.text.isEmpty && controller.phase != .recognizing)

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
            }
            .padding(8)
        }
        .v2GlassBackground(in: RoundedRectangle(cornerRadius: Design.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.panel)
                .strokeBorder(editorFocused ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1.5)
                .allowsHitTesting(false)
        )
    }

    private func capsuleIcon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L(label))
        .accessibilityLabel(L(label))
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
