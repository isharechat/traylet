import AppKit
import SwiftUI

enum EditingToolbarMetrics {
    static let barHeight: CGFloat = 40
    static let buttonSize: CGFloat = 28
    static let barGap: CGFloat = 8
}

struct EditingToolbar: View {
    @ObservedObject var session: EditingSession
    @ObservedObject private var localization = Localization.shared
    let translationMode: Bool
    let ocrMode: Bool
    let copy: () -> Void
    let save: () -> Void
    let translate: () -> Void
    let ocr: () -> Void
    let float: () -> Void
    let cancel: () -> Void
    let drag: (CGSize, Bool) -> Void
    let reset: () -> Void
    let finishText: () -> Bool
    let fitView: () -> Void
    let resetView: () -> Void

    @State private var lastShapeTool: EditingTool = .rectangle
    @State private var lastMaskTool: EditingTool = .blur
    @State private var handleHovering = false

    private var isZoomed: Bool { Int((session.viewport.scale * 100).rounded()) != 100 }
    private var zoomStatus: String { "\(Int((session.viewport.scale * 100).rounded()))%" }
    private var shapeTools: [EditingTool] { [.rectangle, .ellipse, .line] }
    private var maskTools: [EditingTool] { [.blur, .redaction] }
    private var activeShape: EditingTool? {
        guard let tool = session.tool, shapeTools.contains(tool) else { return nil }
        return tool
    }
    private var activeMask: EditingTool? {
        guard let tool = session.tool, maskTools.contains(tool) else { return nil }
        return tool
    }

    var body: some View {
        HStack(spacing: 2.5) {
            dragHandle
            if translationMode {
                EditingPrimaryActionButton(
                    symbol: "translate",
                    title: L("翻译所选区域"),
                    label: L("翻译所选区域"),
                    help: L("翻译所选区域"),
                    action: triggerTranslate
                )
                EditingIconButton(symbol: "xmark", label: L("关闭"), help: L("关闭 Esc"), subtle: true, destructiveHover: true, action: cancel)
            } else if ocrMode {
                EditingPrimaryActionButton(
                    symbol: "text.viewfinder",
                    title: L("识别所选区域"),
                    label: L("识别所选区域"),
                    help: L("识别所选区域"),
                    action: triggerOCR
                )
                EditingIconButton(symbol: "xmark", label: L("关闭"), help: L("关闭 Esc"), subtle: true, destructiveHover: true, action: cancel)
            } else if session.document.canvas.width >= 740 {
                fullFlatToolbarContent
            } else if session.document.canvas.width >= 560 {
                groupedToolbarContent
            } else if session.document.canvas.width >= 280 {
                compactToolbarContent
            } else {
                ultraNarrowToolbarContent
            }
        }
        .padding(.horizontal, 8)
        .frame(height: EditingToolbarMetrics.barHeight)
        .fixedSize(horizontal: true, vertical: false)
        .modifier(EditingSurface())
        .onChange(of: session.tool) { _, newTool in
            guard let newTool else { return }
            if shapeTools.contains(newTool) { lastShapeTool = newTool }
            else if maskTools.contains(newTool) { lastMaskTool = newTool }
        }
        .environment(\.locale, Locale(identifier: localization.english ? "en" : "zh-Hans"))
    }

    private var dragHandle: some View {
        VStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2.5) {
                    Circle().frame(width: 2.2, height: 2.2)
                    Circle().frame(width: 2.2, height: 2.2)
                }
            }
        }
        .foregroundStyle(Color.primary.opacity(handleHovering ? 0.6 : 0.3))
        .frame(width: 14, height: EditingToolbarMetrics.buttonSize)
        .contentShape(Rectangle())
        .onHover { handleHovering = $0 }
        .help(L("拖动移动工具栏，双击复位"))
        .accessibilityLabel(L("移动工具栏"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: L("复位工具栏"), reset)
        .onTapGesture(count: 2, perform: reset)
        // Global space is stable while the hosting view moves, so the bar tracks the pointer without feedback.
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { drag($0.translation, false) }
                .onEnded { drag($0.translation, true) }
        )
    }

    @ViewBuilder private var fullFlatToolbarContent: some View {
        // Zone 1: All 10 annotation tools flat for 1-click access
        HStack(spacing: 2) {
            ForEach(EditingTool.allCases) { tool in
                EditingIconButton(
                    symbol: tool.symbol,
                    glyph: tool == .text ? "T" : nil,
                    label: tool.title,
                    help: toolHelp(tool) ?? tool.title,
                    selected: session.tool == tool
                ) { select(tool) }
                    .accessibilityValue(session.tool == tool ? L("已选择") : L("未选择"))
            }
        }

        ToolbarDivider()

        // Zone 2: History & View
        historyAndViewZone

        ToolbarDivider()

        // Zone 3: Secondary outputs
        secondaryOutputsZone

        ToolbarDivider()

        // Zone 4: Primary confirm & close
        HStack(spacing: 4) {
            EditingPrimaryActionButton(
                symbol: "doc.on.doc",
                title: L("复制"),
                label: L("复制"),
                help: L("复制截图 ⌘C"),
                action: copy
            )
            EditingIconButton(symbol: "xmark", label: L("关闭"), help: L("关闭 Esc"), subtle: true, destructiveHover: true, action: cancel)
        }
    }

    @ViewBuilder private var groupedToolbarContent: some View {
        // Zone 1: Grouped annotation tools
        HStack(spacing: 2) {
            EditingGroupMenuButton(
                symbol: (activeShape ?? lastShapeTool).symbol,
                active: activeShape != nil,
                label: L("图形"),
                help: L("图形")
            ) {
                ForEach(shapeTools) { tool in
                    Button { select(tool) } label: {
                        Label(tool.title, systemImage: session.tool == tool ? "checkmark" : tool.symbol)
                    }
                }
            }
            .accessibilityValue(activeShape?.title ?? L("未选择"))

            ForEach([EditingTool.arrow, .pencil, .text, .number, .highlight]) { tool in
                EditingIconButton(
                    symbol: tool.symbol,
                    glyph: tool == .text ? "T" : nil,
                    label: tool.title,
                    help: toolHelp(tool),
                    selected: session.tool == tool
                ) { select(tool) }
                    .accessibilityValue(session.tool == tool ? L("已选择") : L("未选择"))
            }

            EditingGroupMenuButton(
                symbol: (activeMask ?? lastMaskTool).symbol,
                active: activeMask != nil,
                label: L("模糊与遮挡"),
                help: L("模糊与遮挡")
            ) {
                ForEach(maskTools) { tool in
                    Button { select(tool) } label: {
                        Label(tool.title, systemImage: session.tool == tool ? "checkmark" : tool.symbol)
                    }
                }
            }
            .accessibilityValue(activeMask?.title ?? L("未选择"))
        }

        ToolbarDivider()

        // Zone 2: History & View
        historyAndViewZone

        ToolbarDivider()

        // Zone 3: Secondary outputs
        secondaryOutputsZone

        ToolbarDivider()

        // Zone 4: Primary confirm & close (compact icon-only Copy to fit 560pt+)
        HStack(spacing: 4) {
            EditingIconButton(symbol: "doc.on.doc", label: L("复制"), help: L("复制截图 ⌘C"), prominent: true, action: copy)
            EditingIconButton(symbol: "xmark", label: L("关闭"), help: L("关闭 Esc"), subtle: true, destructiveHover: true, action: cancel)
        }
    }

    @ViewBuilder private var historyAndViewZone: some View {
        HStack(spacing: 2) {
            EditingIconButton(
                symbol: "arrow.uturn.backward",
                label: L("撤销"),
                help: L("撤销 ⌘Z"),
                enabled: session.document.canUndo,
                action: undo
            )
            EditingIconButton(
                symbol: "arrow.uturn.forward",
                label: L("重做"),
                help: L("重做 ⇧⌘Z"),
                enabled: session.document.canRedo,
                action: redo
            )
            zoomOrMoreMenu
        }
    }

    @ViewBuilder private var secondaryOutputsZone: some View {
        HStack(spacing: 2) {
            EditingIconButton(symbol: "translate", label: L("翻译"), help: L("翻译截图"), action: triggerTranslate)
            EditingIconButton(symbol: "text.viewfinder", label: L("OCR"), help: L("OCR 识别"), action: triggerOCR)
            EditingIconButton(symbol: "macwindow", label: L("悬浮"), help: L("悬浮到屏幕最上层 ⌘F"), action: float)
            EditingIconButton(symbol: "square.and.arrow.down", label: L("保存"), help: L("保存 PNG ⌘S"), action: save)
        }
    }

    @ViewBuilder private var compactToolbarContent: some View {
        EditingMenuPillButton(
            symbol: session.tool?.symbol ?? "pencil.tip.crop.circle",
            active: session.tool != nil,
            help: L("标注工具"),
            label: L("标注工具"),
            value: session.tool?.title ?? L("未选择")
        ) {
            groupedToolMenuItems
            Divider()
            undoRedoMenuItems
        }

        Menu {
            viewActionsWithStatus
            Divider()
            Button { triggerTranslate() } label: { Label(L("翻译"), systemImage: "translate") }
            Button { triggerOCR() } label: { Label(L("OCR"), systemImage: "text.viewfinder") }
            Button { float() } label: { Label(L("悬浮"), systemImage: "macwindow") }
        } label: {
            MoreOrZoomLabel(isZoomed: isZoomed, zoomStatus: zoomStatus)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("更多"))
        .accessibilityLabel(isZoomed ? L("视图缩放") : L("更多"))
        .accessibilityValue(zoomStatus)

        ToolbarDivider()

        EditingIconButton(symbol: "square.and.arrow.down", label: L("保存"), help: L("保存 PNG ⌘S"), action: save)
        EditingPrimaryActionButton(
            symbol: "doc.on.doc",
            title: L("复制"),
            label: L("复制"),
            help: L("复制截图 ⌘C"),
            action: copy
        )
        EditingIconButton(symbol: "xmark", label: L("关闭"), help: L("关闭 Esc"), subtle: true, destructiveHover: true, action: cancel)
    }

    @ViewBuilder private var ultraNarrowToolbarContent: some View {
        Menu {
            groupedToolMenuItems
            Divider()
            undoRedoMenuItems
            Divider()
            viewActionsWithStatus
            Divider()
            Button { triggerTranslate() } label: { Label(L("翻译"), systemImage: "translate") }
            Button { triggerOCR() } label: { Label(L("OCR"), systemImage: "text.viewfinder") }
            Button { float() } label: { Label(L("悬浮"), systemImage: "macwindow") }
            Button { cancel() } label: { Label(L("关闭"), systemImage: "xmark") }
        } label: {
            if isZoomed {
                ZoomPillLabel(zoomStatus: zoomStatus)
            } else {
                EditingMenuCircleGlyph(symbol: session.tool?.symbol ?? "pencil.tip.crop.circle", active: session.tool != nil)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("标注工具") + " · " + L("视图缩放"))
        .accessibilityLabel(L("标注工具") + " · " + L("视图缩放"))
        .accessibilityValue(session.tool?.title ?? L("未选择"))

        EditingIconButton(symbol: "square.and.arrow.down", label: L("保存"), help: L("保存 PNG ⌘S"), action: save)
        EditingIconButton(symbol: "doc.on.doc", label: L("复制"), help: L("复制截图 ⌘C"), prominent: true, action: copy)
    }

    private var zoomOrMoreMenu: some View {
        Menu { viewActionsWithStatus } label: {
            MoreOrZoomLabel(isZoomed: isZoomed, zoomStatus: zoomStatus)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("视图缩放") + " · " + L("适配选区") + " ⌘2 · " + L("重置视图") + " ⌘0")
        .accessibilityLabel(isZoomed ? L("视图缩放") : L("更多"))
        .accessibilityValue(zoomStatus)
    }

    @ViewBuilder private var groupedToolMenuItems: some View {
        Section(L("图形")) {
            ForEach(shapeTools) { tool in
                Button { select(tool) } label: {
                    Label(tool.title, systemImage: session.tool == tool ? "checkmark" : tool.symbol)
                }
            }
        }
        Section(L("绘制与文字")) {
            ForEach([EditingTool.arrow, .pencil, .text, .number, .highlight]) { tool in
                Button { select(tool) } label: {
                    Label(tool.title, systemImage: session.tool == tool ? "checkmark" : tool.symbol)
                }
            }
        }
        Section(L("模糊与遮挡")) {
            ForEach(maskTools) { tool in
                Button { select(tool) } label: {
                    Label(tool.title, systemImage: session.tool == tool ? "checkmark" : tool.symbol)
                }
            }
        }
    }

    @ViewBuilder private var undoRedoMenuItems: some View {
        Button(L("撤销") + "  ⌘Z") { undo() }.disabled(!session.document.canUndo)
        Button(L("重做") + "  ⇧⌘Z") { redo() }.disabled(!session.document.canRedo)
    }

    @ViewBuilder private var viewActionsWithStatus: some View {
        Text("\(L("视图缩放")): \(zoomStatus)")
        Divider()
        Button(L("适配选区") + "  ⌘2", action: fitView)
        Button(L("重置视图") + "  ⌘0", action: resetView)
        Divider()
        Text(L("按住空格拖动平移"))
    }

    private func toolHelp(_ tool: EditingTool) -> String? {
        switch tool {
        case .arrow: L("点击已有箭头可选择、移动和修改样式。")
        case .number: L("点击放置编号；选择已有编号可移动、修改样式或按 Delete 删除。")
        case .redaction: L("不透明黑色覆盖，始终显示在其他标注上方。")
        case .highlight: L("固定35%透明度，叠色突出内容。")
        default: nil
        }
    }

    private func select(_ tool: EditingTool) {
        guard finishText() else { return }
        withAnimation(Design.Animation.snappy) {
            session.tool = session.tool == tool ? nil : tool
        }
    }

    private func triggerTranslate() {
        guard finishText() else { return }
        translate()
    }

    private func triggerOCR() {
        guard finishText() else { return }
        ocr()
    }

    private func undo() { guard finishText() else { return }; session.document.undo() }
    private func redo() { guard finishText() else { return }; session.document.redo() }
}

private struct EditingPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.93 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(Design.Animation.snappy, value: configuration.isPressed)
    }
}

/// Hairline vertical separator between toolbar zones.
private struct ToolbarDivider: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(contrast == .increased ? 0.35 : 0.14))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 3)
    }
}

private struct EditingMenuCircleGlyph: View {
    let symbol: String
    let active: Bool
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13.5, weight: active ? .semibold : .regular))
            .frame(width: EditingToolbarMetrics.buttonSize, height: EditingToolbarMetrics.buttonSize)
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .background(
                active ? Color.accentColor.opacity(0.18) : (hovering ? Color.primary.opacity(0.09) : Color.clear),
                in: Circle()
            )
            .overlay {
                if active {
                    Circle().strokeBorder(
                        Color.accentColor.opacity(contrast == .increased ? 0.85 : 0.45),
                        lineWidth: contrast == .increased ? 1.5 : 1
                    )
                }
            }
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

private struct EditingMenuPillButton<MenuContent: View>: View {
    let symbol: String
    let active: Bool
    let help: String
    let label: String
    let value: String
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some View {
        Menu {
            menuContent()
        } label: {
            EditingMenuCircleGlyph(symbol: symbol, active: active)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

private struct ZoomPillLabel: View {
    let zoomStatus: String
    @State private var hovering = false

    var body: some View {
        Text(zoomStatus)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(Color.accentColor.opacity(hovering ? 0.22 : 0.14), in: Capsule())
            .onHover { hovering = $0 }
    }
}

private struct MoreOrZoomLabel: View {
    let isZoomed: Bool
    let zoomStatus: String
    @State private var hovering = false

    var body: some View {
        if isZoomed {
            ZoomPillLabel(zoomStatus: zoomStatus)
        } else {
            Image(systemName: "ellipsis")
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: EditingToolbarMetrics.buttonSize, height: EditingToolbarMetrics.buttonSize)
                .background(hovering ? Color.primary.opacity(0.09) : Color.clear, in: Circle())
                .contentShape(Circle())
                .onHover { hovering = $0 }
        }
    }
}

/// Grouped tool button with a tiny corner chevron indicator opening a native menu.
private struct EditingGroupMenuButton<MenuContent: View>: View {
    let symbol: String
    let active: Bool
    let label: String
    let help: String
    @ViewBuilder let menuContent: () -> MenuContent
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Menu {
            menuContent()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: 13.5, weight: active ? .semibold : .regular))
                    .frame(width: EditingToolbarMetrics.buttonSize, height: EditingToolbarMetrics.buttonSize)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6.5, weight: .bold))
                    .offset(x: -3, y: -3)
            }
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .frame(width: EditingToolbarMetrics.buttonSize, height: EditingToolbarMetrics.buttonSize)
            .background(
                active ? Color.accentColor.opacity(0.18) : (hovering ? Color.primary.opacity(0.09) : Color.clear),
                in: Circle()
            )
            .overlay {
                if active {
                    Circle().strokeBorder(
                        Color.accentColor.opacity(contrast == .increased ? 0.85 : 0.45),
                        lineWidth: contrast == .increased ? 1.5 : 1
                    )
                }
            }
            .contentShape(Circle())
            .onHover { hovering = $0 }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel(label)
    }
}

/// 28pt circular icon button used by the capture toolbar.
private struct EditingIconButton: View {
    let symbol: String
    var glyph: String?
    let label: String
    var help: String?
    var selected = false
    var prominent = false
    var subtle = false
    var destructiveHover = false
    var enabled = true
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var foregroundColor: Color {
        if prominent { return .white }
        if selected { return .accentColor }
        if destructiveHover && hovering && enabled { return .red }
        return subtle ? .secondary : .primary
    }

    private var backgroundColor: Color {
        if prominent { return .accentColor }
        if selected { return Color.accentColor.opacity(0.18) }
        if hovering && enabled {
            return destructiveHover ? Color.red.opacity(0.14) : Color.primary.opacity(0.09)
        }
        return .clear
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let glyph {
                    Text(glyph).font(.system(size: 14.5, weight: selected ? .bold : .semibold))
                } else {
                    Image(systemName: symbol).font(.system(size: 13.5, weight: (selected || prominent) ? .semibold : .regular))
                }
            }
            .foregroundStyle(foregroundColor)
            .frame(width: EditingToolbarMetrics.buttonSize, height: EditingToolbarMetrics.buttonSize)
            .background(backgroundColor, in: Circle())
            .overlay {
                if selected {
                    Circle().strokeBorder(
                        Color.accentColor.opacity(contrast == .increased ? 0.85 : 0.45),
                        lineWidth: contrast == .increased ? 1.5 : 1
                    )
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(EditingPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}

/// Prominent capsule CTA used for primary confirmation actions (Copy / Translate / OCR).
private struct EditingPrimaryActionButton: View {
    let symbol: String
    let title: String
    let label: String
    var help: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .frame(height: EditingToolbarMetrics.buttonSize)
            .background(Color.accentColor, in: Capsule())
            .brightness(hovering ? 0.06 : 0)
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(hovering ? 0.32 : 0.2), lineWidth: 0.75)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(EditingPressStyle())
        .onHover { hovering = $0 }
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}

struct EditingOptions: View {
    @ObservedObject var session: EditingSession
    let colorPanel: EditingColorPanel
    @ObservedObject private var localization = Localization.shared

    private var isWide: Bool { session.document.canvas.width >= 360 }

    var body: some View {
        HStack(spacing: 8) {
            if let tool = session.tool {
                if tool == .highlight {
                    StatusPill(text: "35%", tint: .secondary)
                    ToolbarDivider()
                    if isWide { EditingColorSwatches(session: session) }
                    EditingColorWell(session: session, panel: colorPanel)
                        .frame(width: isWide ? 30 : 36, height: 22)
                } else if tool == .blur {
                    blurSizePresets
                    if isWide {
                        ToolbarDivider()
                        Slider(value: $session.style.brushSize, in: 8...60)
                            .frame(width: 84)
                            .accessibilityLabel(L("模糊画笔直径"))
                        Text("\(Int(session.style.brushSize.rounded()))pt")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                } else if tool != .redaction {
                    if tool == .text || tool == .number {
                        if isWide {
                            fontSizePresets
                            EditingStyleNumberField(session: session, key: \.fontSize, range: 8...96, label: L("字号"))
                                .frame(width: 40, height: 22)
                            ToolbarDivider()
                            EditingColorSwatches(session: session)
                        } else {
                            EditingStyleNumberField(session: session, key: \.fontSize, range: 8...96, label: L("字号"))
                                .frame(width: 44, height: 22)
                        }
                        EditingColorWell(session: session, panel: colorPanel)
                            .frame(width: isWide ? 30 : 36, height: 22)
                    } else {
                        if isWide {
                            strokeWidthPresets
                            EditingStyleNumberField(session: session, key: \.width, range: 1...20, label: L("线条粗细"))
                                .frame(width: 36, height: 22)
                            ToolbarDivider()
                            EditingColorSwatches(session: session)
                        } else {
                            EditingStyleNumberField(session: session, key: \.width, range: 1...20, label: L("线条粗细"))
                                .frame(width: 44, height: 22)
                        }
                        EditingColorWell(session: session, panel: colorPanel)
                            .frame(width: isWide ? 30 : 36, height: 22)
                        if tool == .rectangle || tool == .ellipse {
                            ToolbarDivider()
                            EditingFillToggle(filled: $session.style.filled, isEllipse: tool == .ellipse)
                        }
                    }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: EditingToolbarMetrics.barHeight)
        .fixedSize(horizontal: true, vertical: false)
        .modifier(EditingSurface())
        .id(session.styleControlID)
        .disabled(session.isEditingText)
        .environment(\.locale, Locale(identifier: localization.english ? "en" : "zh-Hans"))
        .help(optionsHelp)
    }

    private var optionsHelp: String {
        switch session.tool {
        case .text: L("单击选择文字，拖动移动；双击或按回车编辑；Command+回车提交，Esc取消。")
        case .number: L("点击放置编号；选择已有编号可移动、修改样式或按 Delete 删除。")
        case .blur: L("高斯模糊是视觉效果，不适用于安全隐藏敏感内容。")
        case .highlight: L("固定35%透明度，叠色突出内容。")
        default: L("工具选项")
        }
    }

    private var blurSizePresets: some View {
        HStack(spacing: 4) {
            ForEach([(CGFloat(14), CGFloat(6), "小"), (CGFloat(24), CGFloat(9), "中"), (CGFloat(40), CGFloat(13), "大")], id: \.0) { value, dotSize, name in
                EditingDotPresetButton(
                    dotSize: dotSize,
                    active: abs(session.style.brushSize - value) < 3,
                    help: "\(L(name)) · \(Int(value))pt",
                    label: "\(L("模糊画笔直径")) \(L(name))",
                    value: "\(Int(value))pt"
                ) {
                    session.style.brushSize = value
                }
            }
        }
    }

    private var strokeWidthPresets: some View {
        HStack(spacing: 4) {
            let current = session.effectiveStyle.width
            ForEach([(CGFloat(2), CGFloat(4), "细"), (CGFloat(4), CGFloat(7), "中"), (CGFloat(8), CGFloat(10), "粗")], id: \.0) { value, dotSize, name in
                EditingDotPresetButton(
                    dotSize: dotSize,
                    active: abs(current - value) < 0.8,
                    help: "\(L(name)) · \(Int(value))pt",
                    label: "\(L("线条粗细")) \(L(name))",
                    value: "\(Int(value))pt"
                ) {
                    setStyle(\.width, value: value)
                }
            }
        }
    }

    private var fontSizePresets: some View {
        HStack(spacing: 2) {
            let current = session.effectiveStyle.fontSize
            ForEach([CGFloat(16), CGFloat(24), CGFloat(36)], id: \.self) { size in
                EditingFontSizePresetButton(
                    size: size,
                    active: abs(current - size) < 1
                ) {
                    setStyle(\.fontSize, value: size)
                }
            }
        }
    }

    private func setStyle(_ key: WritableKeyPath<EditingStyle, CGFloat>, value: CGFloat) {
        let context = session.captureStyleContext()
        var next = session.effectiveStyle
        next[keyPath: key] = value
        _ = session.setEffectiveStyle(next, context: context)
    }
}

private struct EditingDotPresetButton: View {
    let dotSize: CGFloat
    let active: Bool
    let help: String
    let label: String
    let value: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(active ? Color.accentColor : Color.primary.opacity(hovering ? 0.9 : 0.7))
                .frame(width: dotSize, height: dotSize)
                .frame(width: 26, height: 26)
                .background(
                    active ? Color.accentColor.opacity(0.18) : (hovering ? Color.primary.opacity(0.08) : Color.clear),
                    in: Circle()
                )
                .overlay {
                    if active {
                        Circle().strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(EditingPressStyle())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

private struct EditingFontSizePresetButton: View {
    let size: CGFloat
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("\(Int(size))")
                .font(.system(size: 11, weight: active ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(width: 26, height: 24)
                .background(
                    active ? Color.accentColor.opacity(0.18) : (hovering ? Color.primary.opacity(0.08) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay {
                    if active {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(EditingPressStyle())
        .onHover { hovering = $0 }
        .help("\(L("字号")) \(Int(size))")
        .accessibilityLabel("\(L("字号")) \(Int(size))")
    }
}

private struct EditingColorSwatches: View {
    @ObservedObject var session: EditingSession

    private static let presets: [(NSColor, String)] = [
        (.systemRed, "红色"),
        (.systemOrange, "橙色"),
        (.systemYellow, "黄色"),
        (.systemGreen, "绿色"),
        (.systemBlue, "蓝色"),
        (.white, "白色"),
        (.black, "黑色")
    ]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Self.presets, id: \.1) { color, name in
                let selected = colorsMatch(session.effectiveStyle.color, color)
                EditingColorSwatchButton(color: color, name: name, selected: selected) {
                    let context = session.captureStyleContext()
                    var next = session.effectiveStyle
                    next.color = color
                    _ = session.setEffectiveStyle(next, context: context)
                }
            }
        }
    }

    private func colorsMatch(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let a = lhs.usingColorSpace(.sRGB), let b = rhs.usingColorSpace(.sRGB) else {
            return lhs.isEqual(rhs)
        }
        return abs(a.redComponent - b.redComponent) < 0.05
            && abs(a.greenComponent - b.greenComponent) < 0.05
            && abs(a.blueComponent - b.blueComponent) < 0.05
    }
}

private struct EditingColorSwatchButton: View {
    let color: NSColor
    let name: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: 16, height: 16)
                .overlay {
                    Circle().strokeBorder(
                        selected ? Color.white.opacity(0.95) : Color.primary.opacity(0.22),
                        lineWidth: selected ? 1.5 : 0.75
                    )
                }
                .overlay {
                    if selected {
                        Circle()
                            .stroke(Color.accentColor, lineWidth: 1.5)
                            .frame(width: 20, height: 20)
                    }
                }
                .scaleEffect(hovering && !reduceMotion ? 1.12 : 1.0)
                .frame(width: 20, height: 20)
                .contentShape(Circle())
                .animation(Design.Animation.snappy, value: hovering)
        }
        .buttonStyle(EditingPressStyle())
        .onHover { hovering = $0 }
        .help(L(name))
        .accessibilityLabel(L(name))
        .accessibilityValue(selected ? L("已选择") : L("未选择"))
    }
}

private struct EditingFillToggle: View {
    @Binding var filled: Bool
    let isEllipse: Bool
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button {
            filled.toggle()
        } label: {
            Image(systemName: isEllipse ? (filled ? "circle.fill" : "circle") : (filled ? "square.fill" : "square"))
                .font(.system(size: 13.5, weight: filled ? .semibold : .regular))
                .foregroundStyle(filled ? Color.accentColor : Color.primary)
                .frame(width: EditingToolbarMetrics.buttonSize, height: EditingToolbarMetrics.buttonSize)
                .background(
                    filled ? Color.accentColor.opacity(0.18) : (hovering ? Color.primary.opacity(0.09) : .clear),
                    in: Circle()
                )
                .overlay {
                    if filled {
                        Circle().strokeBorder(
                            Color.accentColor.opacity(contrast == .increased ? 0.85 : 0.45),
                            lineWidth: contrast == .increased ? 1.5 : 1
                        )
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(EditingPressStyle())
        .onHover { hovering = $0 }
        .help(L("填充"))
        .accessibilityLabel(L("填充"))
        .accessibilityValue(filled ? L("已选择") : L("未选择"))
    }
}

private struct EditingSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.v2GlassBackground(in: Capsule(), interactive: true, elevated: true)
    }
}
