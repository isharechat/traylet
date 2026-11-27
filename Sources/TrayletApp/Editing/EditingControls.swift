import AppKit
import SwiftUI

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
        HStack(spacing: 4) {
            dragHandle
            if translationMode {
                Button(L("翻译所选区域"), action: triggerTranslate)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                EditingIconButton(symbol: "xmark", label: L("关闭"), help: L("关闭 Esc"), subtle: true, action: cancel)
            } else if ocrMode {
                Button(L("识别所选区域"), action: triggerOCR)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                EditingIconButton(symbol: "xmark", label: L("关闭"), help: L("关闭 Esc"), subtle: true, action: cancel)
            } else if session.document.canvas.width >= 540 {
                fullToolbarContent
            } else if session.document.canvas.width >= 260 {
                compactToolbarContent
            } else {
                ultraNarrowToolbarContent
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 36)
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
        Image(systemName: "ellipsis")
            .rotationEffect(.degrees(90))
            .foregroundStyle(handleHovering ? .secondary : .tertiary)
            .frame(width: 14, height: 28)
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

    @ViewBuilder private var fullToolbarContent: some View {
        // Zone 1: Annotation tools
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

        ToolbarDivider()

        // Zone 3: Secondary outputs
        HStack(spacing: 2) {
            EditingIconButton(symbol: "translate", label: L("翻译"), help: L("翻译截图"), action: triggerTranslate)
            EditingIconButton(symbol: "text.viewfinder", label: L("OCR"), help: L("OCR 识别"), action: triggerOCR)
            EditingIconButton(symbol: "macwindow", label: L("悬浮"), help: L("悬浮到屏幕最上层 ⌘F"), action: float)
            EditingIconButton(symbol: "square.and.arrow.down", label: L("保存"), help: L("保存 PNG ⌘S"), action: save)
        }

        ToolbarDivider()

        // Zone 4: Primary confirm & close
        HStack(spacing: 4) {
            EditingIconButton(symbol: "doc.on.doc", label: L("复制"), help: L("复制截图 ⌘C"), prominent: true, action: copy)
            EditingIconButton(symbol: "xmark", label: L("关闭"), help: L("关闭 Esc"), subtle: true, action: cancel)
        }
    }

    @ViewBuilder private var compactToolbarContent: some View {
        Menu {
            groupedToolMenuItems
            Divider()
            undoRedoMenuItems
        } label: {
            Image(systemName: session.tool?.symbol ?? "pencil.tip.crop.circle")
                .font(.system(size: 13))
                .frame(width: Design.iconButton, height: Design.iconButton)
                .foregroundStyle(session.tool == nil ? Color.primary : Color.accentColor)
                .background(session.tool == nil ? Color.clear : Color.accentColor.opacity(0.2), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("标注工具"))
        .accessibilityLabel(L("标注工具"))
        .accessibilityValue(session.tool?.title ?? L("未选择"))

        Menu {
            viewActionsWithStatus
            Divider()
            Button { triggerTranslate() } label: { Label(L("翻译"), systemImage: "translate") }
            Button { triggerOCR() } label: { Label(L("OCR"), systemImage: "text.viewfinder") }
            Button { float() } label: { Label(L("悬浮"), systemImage: "macwindow") }
        } label: {
            moreOrZoomLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("更多"))
        .accessibilityLabel(isZoomed ? L("视图缩放") : L("更多"))
        .accessibilityValue(zoomStatus)

        ToolbarDivider()

        EditingIconButton(symbol: "square.and.arrow.down", label: L("保存"), help: L("保存 PNG ⌘S"), action: save)
        EditingIconButton(symbol: "doc.on.doc", label: L("复制"), help: L("复制截图 ⌘C"), prominent: true, action: copy)
        EditingIconButton(symbol: "xmark", label: L("关闭"), help: L("关闭 Esc"), subtle: true, action: cancel)
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
                Text(zoomStatus)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            } else {
                Image(systemName: session.tool?.symbol ?? "pencil.tip.crop.circle")
                    .font(.system(size: 13))
                    .frame(width: Design.iconButton, height: Design.iconButton)
                    .foregroundStyle(session.tool == nil ? Color.primary : Color.accentColor)
                    .background(session.tool == nil ? Color.clear : Color.accentColor.opacity(0.2), in: Circle())
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
            moreOrZoomLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("视图缩放") + " · " + L("适配选区") + " ⌘2 · " + L("重置视图") + " ⌘0")
        .accessibilityLabel(isZoomed ? L("视图缩放") : L("更多"))
        .accessibilityValue(zoomStatus)
    }

    @ViewBuilder private var moreOrZoomLabel: some View {
        if isZoomed {
            Text(zoomStatus)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
        } else {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: Design.iconButton, height: Design.iconButton)
                .contentShape(Circle())
        }
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

/// Hairline vertical separator between toolbar zones.
private struct ToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 3)
    }
}

/// Grouped tool button with a tiny corner chevron indicator opening a native menu.
private struct EditingGroupMenuButton<MenuContent: View>: View {
    let symbol: String
    let active: Bool
    let label: String
    let help: String
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some View {
        Menu {
            menuContent()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: Design.iconButton, height: Design.iconButton)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6.5, weight: .bold))
                    .offset(x: -3, y: -3)
            }
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .frame(width: Design.iconButton, height: Design.iconButton)
            .background(active ? Color.accentColor.opacity(0.2) : Color.clear, in: Circle())
            .contentShape(Circle())
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
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let glyph { Text(glyph).font(.system(size: 15, weight: .semibold)) }
                else { Image(systemName: symbol).font(.system(size: 13, weight: .regular)) }
            }
            // Only the main action (copy) is a filled accent circle; a chosen tool is a tinted circle with an accent glyph.
            .foregroundStyle(
                prominent ? Color.white :
                (selected ? Color.accentColor :
                (subtle ? Color.secondary : Color.primary))
            )
            .frame(width: Design.iconButton, height: Design.iconButton)
            .background(
                prominent ? Color.accentColor :
                (selected ? Color.accentColor.opacity(0.2) :
                (hovering ? Color.primary.opacity(0.1) : .clear)),
                in: Circle()
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
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
                    Text("35%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
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
        .frame(height: 36)
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
                let active = abs(session.style.brushSize - value) < 3
                Button {
                    session.style.brushSize = value
                } label: {
                    Circle()
                        .fill(active ? Color.accentColor : Color.primary.opacity(0.65))
                        .frame(width: dotSize, height: dotSize)
                        .frame(width: 24, height: 24)
                        .background(active ? Color.accentColor.opacity(0.18) : Color.clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("\(L(name)) · \(Int(value))pt")
                .accessibilityLabel("\(L("模糊画笔直径")) \(L(name))")
                .accessibilityValue("\(Int(value))pt")
            }
        }
    }

    private var strokeWidthPresets: some View {
        HStack(spacing: 4) {
            let current = session.effectiveStyle.width
            ForEach([(CGFloat(2), CGFloat(4), "细"), (CGFloat(4), CGFloat(7), "中"), (CGFloat(8), CGFloat(10), "粗")], id: \.0) { value, dotSize, name in
                let active = abs(current - value) < 0.8
                Button {
                    setStyle(\.width, value: value)
                } label: {
                    Circle()
                        .fill(active ? Color.accentColor : Color.primary.opacity(0.7))
                        .frame(width: dotSize, height: dotSize)
                        .frame(width: 24, height: 24)
                        .background(active ? Color.accentColor.opacity(0.18) : Color.clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("\(L(name)) · \(Int(value))pt")
                .accessibilityLabel("\(L("线条粗细")) \(L(name))")
                .accessibilityValue("\(Int(value))pt")
            }
        }
    }

    private var fontSizePresets: some View {
        HStack(spacing: 2) {
            let current = session.effectiveStyle.fontSize
            ForEach([CGFloat(16), CGFloat(24), CGFloat(36)], id: \.self) { size in
                let active = abs(current - size) < 1
                Button {
                    setStyle(\.fontSize, value: size)
                } label: {
                    Text("\(Int(size))")
                        .font(.system(size: 11, weight: active ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(active ? Color.accentColor : Color.primary)
                        .frame(width: 24, height: 22)
                        .background(active ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(L("字号")) \(Int(size))")
                .accessibilityLabel("\(L("字号")) \(Int(size))")
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

private struct EditingColorSwatches: View {
    @ObservedObject var session: EditingSession

    private static let presets: [(NSColor, String)] = [
        (.systemRed, "红色"),
        (.systemOrange, "橙色"),
        (.systemYellow, "黄色"),
        (.systemGreen, "绿色"),
        (.systemBlue, "蓝色"),
        (.black, "黑色")
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.presets, id: \.1) { color, name in
                let selected = colorsMatch(session.effectiveStyle.color, color)
                Button {
                    let context = session.captureStyleContext()
                    var next = session.effectiveStyle
                    next.color = color
                    _ = session.setEffectiveStyle(next, context: context)
                } label: {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 16, height: 16)
                        .overlay {
                            Circle().strokeBorder(Color.white.opacity(selected ? 0.95 : 0.35), lineWidth: selected ? 1.5 : 0.5)
                        }
                        .overlay {
                            if selected {
                                Circle()
                                    .stroke(Color.accentColor, lineWidth: 1.5)
                                    .frame(width: 20, height: 20)
                            }
                        }
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L(name))
                .accessibilityLabel(L(name))
                .accessibilityValue(selected ? L("已选择") : L("未选择"))
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

private struct EditingFillToggle: View {
    @Binding var filled: Bool
    let isEllipse: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            filled.toggle()
        } label: {
            Image(systemName: isEllipse ? (filled ? "circle.fill" : "circle") : (filled ? "square.fill" : "square"))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(filled ? Color.accentColor : Color.primary)
                .frame(width: Design.iconButton, height: Design.iconButton)
                .background(
                    filled ? Color.accentColor.opacity(0.2) : (hovering ? Color.primary.opacity(0.1) : .clear),
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
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
