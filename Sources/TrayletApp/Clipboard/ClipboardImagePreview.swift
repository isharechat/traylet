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

    static func clampedPanOffset(
        proposed: CGSize,
        imageSize: CGSize,
        viewportSize: CGSize
    ) -> CGSize {
        func clampAxis(_ offset: CGFloat, imageSpan: CGFloat, viewportSpan: CGFloat) -> CGFloat {
            guard offset.isFinite, imageSpan.isFinite, viewportSpan.isFinite else { return 0 }
            let limit: CGFloat = if imageSpan > viewportSpan {
                (imageSpan - viewportSpan) / 2 + 16
            } else {
                max(0, (viewportSpan - imageSpan) / 2)
            }
            return min(limit, max(-limit, offset))
        }
        return CGSize(
            width: clampAxis(proposed.width, imageSpan: imageSize.width, viewportSpan: viewportSize.width),
            height: clampAxis(proposed.height, imageSpan: imageSize.height, viewportSpan: viewportSize.height)
        )
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
    @State private var panOffset: CGSize = .zero
    @State private var dragBaseOffset: CGSize?

    init(feature: ClipboardFeature, entry: ClipboardEntry) {
        self.feature = feature
        self.controller = feature.controller
        self.imageEditing = feature.imageEditing
        self.entry = entry
    }

    private var naturalImageSize: CGSize {
        if let pixelSize, pixelSize.width > 0, pixelSize.height > 0 {
            let scale = max(1.0, NSScreen.main?.backingScaleFactor ?? 2.0)
            return CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        }
        return image?.size ?? .zero
    }

    private var fitScale: CGFloat {
        let base = naturalImageSize
        guard base.width > 0, base.height > 0,
              viewportSize.width > 24, viewportSize.height > 24 else { return 1.0 }
        let maxW = viewportSize.width - 24
        let maxH = viewportSize.height - 24
        return min(1.0, min(maxW / base.width, maxH / base.height))
    }

    private var currentScale: CGFloat {
        zoom.effectiveScale(currentFitScale: fitScale)
    }

    private var renderedImageSize: CGSize {
        let base = naturalImageSize
        return CGSize(width: max(1, base.width * currentScale), height: max(1, base.height * currentScale))
    }

    var body: some View {
        let currentEntry = controller.entries.first(where: { $0.id == entry.id }) ?? entry
        VStack(spacing: 0) {
            header(entry: currentEntry)
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(.horizontal, 14)
                .frame(height: 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mac27ContentSurface()
        .ignoresSafeArea(.container, edges: .top)
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
                Button { setZoom(zoom.zoomIn(currentFitScale: fitScale)) } label: { EmptyView() }
                    .keyboardShortcut("=", modifiers: [.command])
                Button { setZoom(zoom.zoomOut(currentFitScale: fitScale)) } label: { EmptyView() }
                    .keyboardShortcut("-", modifiers: [.command])
                Button { setZoom(.fit, resetPan: true) } label: { EmptyView() }
                    .keyboardShortcut("0", modifiers: [.command])
                Button { setZoom(.scale(1.0), resetPan: true) } label: { EmptyView() }
                    .keyboardShortcut("1", modifiers: [.command])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .task(id: entry.id) {
            image = nil
            zoom = .fit
            panOffset = .zero
            dragBaseOffset = nil
            guard let data = currentEntry.imageData else { pixelSize = nil; return }
            pixelSize = ClipboardEntry.imagePixelSize(for: data)
            image = await ClipboardThumbnails.fullImage(data, key: currentEntry.digest)
        }
    }

    private func setZoom(_ next: ClipboardImageZoom, resetPan: Bool = false) {
        zoom = next
        if resetPan {
            panOffset = .zero
            dragBaseOffset = nil
        } else {
            let base = naturalImageSize
            let nextScale = next.effectiveScale(currentFitScale: fitScale)
            let nextImageSize = CGSize(width: max(1, base.width * nextScale), height: max(1, base.height * nextScale))
            panOffset = ClipboardImageZoom.clampedPanOffset(proposed: panOffset, imageSize: nextImageSize, viewportSize: viewportSize)
        }
    }

    private func header(entry: ClipboardEntry) -> some View {
        let indices = ClipboardImageEditing.imageIndices(in: entry)
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file)
        return Mac27ToolbarBar(leadingPadding: Design.Layout.trafficLightsClearance, trailingPadding: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(entry.application)
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        StatusPill(text: L("图片"), tint: .purple)
                    }
                    HStack(spacing: 5) {
                        Text(entry.capturedAt.formatted(date: .abbreviated, time: .shortened))
                        if let pixelSize {
                            Text("·")
                            Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px")
                        }
                        Text("·")
                        Text(sizeText)
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Mac27GlassCapsule(spacing: 2, horizontalPadding: 4) {
                if indices.count == 1, let index = indices.first {
                    WorkspaceIconButton(
                        symbol: "text.viewfinder",
                        label: "OCR 识别",
                        help: "OCR 识别",
                        disabled: imageEditing.isPreparing
                    ) {
                        feature.openOCRImage(entry.id, itemIndex: index)
                    }
                    WorkspaceIconButton(
                        symbol: "character.bubble",
                        label: "截图翻译",
                        help: "截图翻译",
                        disabled: imageEditing.isPreparing
                    ) {
                        feature.recognizeImage(entry.id, itemIndex: index)
                    }
                    WorkspaceIconButton(
                        symbol: "pencil",
                        label: "编辑图片",
                        help: "编辑副本，保留历史原件",
                        disabled: imageEditing.isPreparing
                    ) {
                        feature.editImage(entry.id, itemIndex: index)
                    }
                } else if !indices.isEmpty {
                    previewMultiImageActionMenu(symbol: "text.viewfinder", label: "OCR 识别", help: "OCR 识别", indices: indices) { index in
                        feature.openOCRImage(entry.id, itemIndex: index)
                    }
                    previewMultiImageActionMenu(symbol: "character.bubble", label: "截图翻译", help: "截图翻译", indices: indices) { index in
                        feature.recognizeImage(entry.id, itemIndex: index)
                    }
                    previewMultiImageActionMenu(symbol: "pencil", label: "编辑图片", help: "编辑副本，保留历史原件", indices: indices) { index in
                        feature.editImage(entry.id, itemIndex: index)
                    }
                }
                WorkspaceIconButton(
                    symbol: entry.favorite ? "star.fill" : "star",
                    label: entry.favorite ? "取消收藏" : "收藏",
                    tint: entry.favorite ? .orange : nil
                ) {
                    feature.runMutation { await controller.toggleFavorite(entry.id) }
                }
                CopyIconButton(label: "复制") {
                    controller.copy(entry.id)
                }
            }
        }
    }

    private func previewMultiImageActionMenu(
        symbol: String,
        label: String,
        help: String,
        indices: [Int],
        action: @escaping (Int) -> Void
    ) -> some View {
        Menu {
            ForEach(Array(indices.enumerated()), id: \.element) { offset, index in
                Button(String(format: L("图片 %d"), offset + 1)) { action(index) }
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .frame(width: Design.iconButton, height: Design.iconButton)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(imageEditing.isPreparing)
        .opacity(imageEditing.isPreparing ? 0.4 : 1)
        .help(L(help))
        .accessibilityLabel(L(label))
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let imageSize = renderedImageSize
            let effectiveOffset = ClipboardImageZoom.clampedPanOffset(
                proposed: panOffset,
                imageSize: imageSize,
                viewportSize: geometry.size
            )
            ZStack {
                Color.clear
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: imageSize.width, height: imageSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.control))
                        .overlay(
                            RoundedRectangle(cornerRadius: Design.Radius.control)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                        )
                        .offset(effectiveOffset)
                        .modifier(GrabCursorModifier(dragging: dragBaseOffset != nil))
                } else {
                    ProgressView()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard image != nil else { return }
                        let base = dragBaseOffset ?? effectiveOffset
                        if dragBaseOffset == nil { dragBaseOffset = base }
                        panOffset = ClipboardImageZoom.clampedPanOffset(
                            proposed: CGSize(
                                width: base.width + value.translation.width,
                                height: base.height + value.translation.height
                            ),
                            imageSize: renderedImageSize,
                            viewportSize: geometry.size
                        )
                    }
                    .onEnded { value in
                        guard image != nil else { dragBaseOffset = nil; return }
                        let base = dragBaseOffset ?? effectiveOffset
                        panOffset = ClipboardImageZoom.clampedPanOffset(
                            proposed: CGSize(
                                width: base.width + value.translation.width,
                                height: base.height + value.translation.height
                            ),
                            imageSize: renderedImageSize,
                            viewportSize: geometry.size
                        )
                        dragBaseOffset = nil
                    }
            )
            .onTapGesture(count: 2) {
                guard image != nil else { return }
                if zoom == .fit {
                    setZoom(fitScale < 0.98 ? .scale(1.0) : .scale(1.5), resetPan: true)
                } else {
                    setZoom(.fit, resetPan: true)
                }
            }
            .onAppear { viewportSize = geometry.size }
            .onChange(of: geometry.size) { _, newValue in
                viewportSize = newValue
                panOffset = ClipboardImageZoom.clampedPanOffset(
                    proposed: panOffset,
                    imageSize: renderedImageSize,
                    viewportSize: newValue
                )
            }
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
                setZoom(zoom.zoomOut(currentFitScale: fitScale))
            }
            zoomModeButton(title: L("适应"), active: zoom == .fit) {
                setZoom(.fit, resetPan: true)
            }
            zoomModeButton(title: L("实际大小"), active: zoom == .scale(1.0)) {
                setZoom(.scale(1.0), resetPan: true)
            }
            WorkspaceIconButton(
                symbol: "plus.magnifyingglass",
                label: "放大",
                size: 24,
                iconSize: 12,
                disabled: image == nil || currentScale >= ClipboardImageZoom.maxScale - 0.001
            ) {
                setZoom(zoom.zoomIn(currentFitScale: fitScale))
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

private struct GrabCursorModifier: ViewModifier {
    let dragging: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(dragging ? .grabActive : .grabIdle)
        } else {
            content
        }
    }
}
