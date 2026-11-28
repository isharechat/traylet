import AppKit
import SwiftUI

/// Zoom state and bounded step arithmetic for the clipboard image lightbox preview.
enum ClipboardImageZoom: Equatable, Sendable {
    case fit
    case scale(CGFloat)

    static let minScale: CGFloat = 0.25
    static let maxScale: CGFloat = 4.0
    static let factor: CGFloat = 1.25

    static func clamped(_ value: CGFloat) -> CGFloat {
        let finite = value.isFinite ? value : 1.0
        return min(maxScale, max(minScale, finite))
    }

    func zoomIn(currentFitScale: CGFloat = 1.0) -> ClipboardImageZoom {
        .scale(Self.clamped(effectiveScale(currentFitScale: currentFitScale) * Self.factor))
    }

    func zoomOut(currentFitScale: CGFloat = 1.0) -> ClipboardImageZoom {
        .scale(Self.clamped(effectiveScale(currentFitScale: currentFitScale) / Self.factor))
    }

    func effectiveScale(currentFitScale: CGFloat = 1.0) -> CGFloat {
        switch self {
        case .fit: currentFitScale > 0 && currentFitScale.isFinite ? currentFitScale : 1.0
        case .scale(let value): Self.clamped(value)
        }
    }

    func displayPercentage(currentFitScale: CGFloat = 1.0) -> Int {
        max(1, Int((effectiveScale(currentFitScale: currentFitScale) * 100).rounded()))
    }
}

/// Thumbnail grid card used when the Clipboard window is filtered to the Images category.
@MainActor struct ClipboardImageGridCard<MenuContent: View>: View {
    let entry: ClipboardEntry
    let selected: Bool
    let relativeTime: String
    let onSelect: () -> Void
    let onCopyAndClose: () -> Void
    let onPreview: () -> Void
    let onToggleFavorite: () -> Void
    let onCopy: () -> Void
    @ViewBuilder let menuContent: () -> MenuContent

    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Color.primary.opacity(0.05)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        if let thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 20))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.control))
                    .overlay(
                        RoundedRectangle(cornerRadius: Design.Radius.control)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
                    )

                if hovering {
                    HStack(spacing: 2) {
                        WorkspaceIconButton(symbol: "eye", label: "预览", help: "预览图片", size: 22, iconSize: 11, action: onPreview)
                        WorkspaceIconButton(
                            symbol: entry.favorite ? "star.fill" : "star",
                            label: entry.favorite ? "取消收藏" : "收藏",
                            tint: entry.favorite ? .yellow : nil,
                            size: 22,
                            iconSize: 11,
                            action: onToggleFavorite
                        )
                        CopyIconButton(label: "复制", size: 22, iconSize: 11, action: onCopy)
                    }
                    .padding(3)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5))
                    .padding(5)
                }
            }

            HStack(spacing: 4) {
                Text(entry.application)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if entry.favorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.yellow)
                        .accessibilityLabel(L("已收藏"))
                }
                Text(relativeTime)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)
        }
        .padding(6)
        .background(
            selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(hovering ? 0.06 : 0.03),
            in: RoundedRectangle(cornerRadius: Design.Radius.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.card)
                .strokeBorder(
                    selected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(hovering ? 0.55 : 0.35),
                    lineWidth: selected ? 1.5 : 0.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: Design.Radius.card))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onCopyAndClose() }
        .onTapGesture(count: 1) { onSelect() }
        .contextMenu { menuContent() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("图片") + ", " + entry.application)
        .task(id: entry.id) {
            thumbnail = nil
            guard let data = entry.imageData else { return }
            thumbnail = await ClipboardThumbnails.image(data, key: entry.digest, maxPixels: 400, size: nil)
        }
    }
}

/// Standalone zoomable image lightbox preview hosted in ClipboardFeature's image preview panel.
@MainActor struct ClipboardImagePreviewView: View {
    @ObservedObject private var feature: ClipboardFeature
    @ObservedObject private var controller: ClipboardController
    @ObservedObject private var imageEditing: ClipboardImageEditing
    let entry: ClipboardEntry

    @State private var image: NSImage?
    @State private var pixelSize: CGSize?
    @State private var zoom: ClipboardImageZoom = .fit
    @State private var viewportSize: CGSize = .zero

    init(feature: ClipboardFeature, entry: ClipboardEntry) {
        self.feature = feature
        self.controller = feature.controller
        self.imageEditing = feature.imageEditing
        self.entry = entry
    }

    private var fitScale: CGFloat {
        guard let image, image.size.width > 0, image.size.height > 0,
              viewportSize.width > 32, viewportSize.height > 32 else { return 1.0 }
        let maxW = viewportSize.width - 32
        let maxH = viewportSize.height - 32
        return min(1.0, min(maxW / image.size.width, maxH / image.size.height))
    }

    private var currentScale: CGFloat {
        zoom.effectiveScale(currentFitScale: fitScale)
    }

    var body: some View {
        let currentEntry = controller.entries.first(where: { $0.id == entry.id }) ?? entry
        VStack(spacing: 0) {
            header(entry: currentEntry)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.controlActiveState, feature.isWindowFocused ? .key : .inactive)
        .onExitCommand { feature.closeImagePreview() }
        .background {
            Group {
                Button { feature.closeImagePreview() } label: { EmptyView() }
                    .keyboardShortcut(.space, modifiers: [])
                Button { feature.closeImagePreview() } label: { EmptyView() }
                    .keyboardShortcut("y", modifiers: [.command])
                Button { controller.copy(currentEntry.id) } label: { EmptyView() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button { zoom = zoom.zoomIn(currentFitScale: fitScale) } label: { EmptyView() }
                    .keyboardShortcut("=", modifiers: [.command])
                Button { zoom = zoom.zoomOut(currentFitScale: fitScale) } label: { EmptyView() }
                    .keyboardShortcut("-", modifiers: [.command])
                Button { zoom = .fit } label: { EmptyView() }
                    .keyboardShortcut("0", modifiers: [.command])
                Button { zoom = .scale(1.0) } label: { EmptyView() }
                    .keyboardShortcut("1", modifiers: [.command])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .task(id: entry.id) {
            image = nil
            zoom = .fit
            guard let data = currentEntry.imageData else { pixelSize = nil; return }
            pixelSize = ClipboardEntry.imagePixelSize(for: data)
            image = await ClipboardThumbnails.fullImage(data, key: currentEntry.digest)
        }
    }

    private func header(entry: ClipboardEntry) -> some View {
        let indices = ClipboardImageEditing.imageIndices(in: entry)
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file)
        return HStack(spacing: 10) {
            Image(systemName: ClipboardKind.image.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 28, height: 28)
                .background(Color.indigo.opacity(0.14), in: RoundedRectangle(cornerRadius: Design.Radius.badge))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.application)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    StatusPill(text: L("图片"), tint: .indigo)
                }
                HStack(spacing: 6) {
                    Text(entry.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    if let pixelSize {
                        Text("·")
                        Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px")
                    }
                    Text("·")
                    Text(sizeText)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            HStack(spacing: 2) {
                if indices.count == 1, let index = indices.first {
                    WorkspaceIconButton(
                        symbol: "pencil",
                        label: "编辑图片",
                        help: "编辑副本，保留历史原件",
                        size: 26,
                        iconSize: 12,
                        disabled: imageEditing.isPreparing
                    ) {
                        feature.editImage(entry.id, itemIndex: index)
                    }
                    WorkspaceIconButton(
                        symbol: "text.viewfinder",
                        label: "识别文字",
                        help: "本机识别，校正后再翻译",
                        size: 26,
                        iconSize: 12,
                        disabled: imageEditing.isPreparing
                    ) {
                        feature.recognizeImage(entry.id, itemIndex: index)
                    }
                }
                WorkspaceIconButton(
                    symbol: entry.favorite ? "star.fill" : "star",
                    label: entry.favorite ? "取消收藏" : "收藏",
                    tint: entry.favorite ? .yellow : nil,
                    size: 26,
                    iconSize: 12
                ) {
                    feature.runMutation { await controller.toggleFavorite(entry.id) }
                }
                CopyIconButton(label: "复制", size: 26, iconSize: 12) {
                    controller.copy(entry.id)
                }
            }
        }
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let availableWidth = max(1, geometry.size.width - 32)
            let availableHeight = max(1, geometry.size.height - 32)
            Group {
                if let image {
                    switch zoom {
                    case .fit:
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: availableWidth, maxHeight: availableHeight)
                            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.control))
                            .overlay(
                                RoundedRectangle(cornerRadius: Design.Radius.control)
                                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                            )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    case .scale(let scale):
                        let scaledWidth = max(1, image.size.width * scale)
                        let scaledHeight = max(1, image.size.height * scale)
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: image)
                                .resizable()
                                .frame(width: scaledWidth, height: scaledHeight)
                                .clipShape(RoundedRectangle(cornerRadius: Design.Radius.control))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Design.Radius.control)
                                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                                )
                                .padding(16)
                                .frame(
                                    minWidth: geometry.size.width,
                                    minHeight: geometry.size.height,
                                    alignment: .center
                                )
                        }
                    }
                } else {
                    ProgressView()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .onAppear { viewportSize = geometry.size }
            .onChange(of: geometry.size) { _, newValue in viewportSize = newValue }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            WorkspaceIconButton(
                symbol: "minus.magnifyingglass",
                label: "缩小",
                size: 24,
                iconSize: 12,
                disabled: image == nil || currentScale <= ClipboardImageZoom.minScale + 0.001
            ) {
                zoom = zoom.zoomOut(currentFitScale: fitScale)
            }
            zoomModeButton(title: L("适应"), active: zoom == .fit) {
                zoom = .fit
            }
            zoomModeButton(title: L("实际大小"), active: zoom == .scale(1.0)) {
                zoom = .scale(1.0)
            }
            WorkspaceIconButton(
                symbol: "plus.magnifyingglass",
                label: "放大",
                size: 24,
                iconSize: 12,
                disabled: image == nil || currentScale >= ClipboardImageZoom.maxScale - 0.001
            ) {
                zoom = zoom.zoomIn(currentFitScale: fitScale)
            }
            Text("\(zoom.displayPercentage(currentFitScale: fitScale))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 38, alignment: .leading)
            Spacer(minLength: 8)
            Text(L("Esc 关闭"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func zoomModeButton(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(active ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(image == nil)
    }
}
