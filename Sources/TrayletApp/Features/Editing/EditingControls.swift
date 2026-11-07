import AppKit
import SwiftUI

struct EditingToolbar: View {
    @ObservedObject var session: EditingSession
    @ObservedObject private var localization = V2Localization.shared
    let translationMode: Bool
    let copy: () -> Void
    let save: () -> Void
    let translate: () -> Void
    let float: () -> Void
    let drag: (CGSize, Bool) -> Void
    let reset: () -> Void
    let finishText: () -> Bool
    let fitView: () -> Void
    let resetView: () -> Void

    var body: some View {
        HStack(spacing:4) {
            Image(systemName:"ellipsis").rotationEffect(.degrees(90)).foregroundStyle(.secondary)
                .frame(width:16,height:28).contentShape(Rectangle())
                .help(V2L("拖动移动工具栏，双击复位"))
                .accessibilityLabel(V2L("移动工具栏"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named:V2L("复位工具栏"),reset)
                .onTapGesture(count:2,perform:reset)
                // Global space is stable while the hosting view moves, so the bar tracks the pointer without feedback.
                .gesture(DragGesture(minimumDistance:2,coordinateSpace:.global)
                    .onChanged { drag($0.translation,false) }.onEnded { drag($0.translation,true) })
            if translationMode {
                Button(V2L("翻译所选区域"),action:translate).buttonStyle(.borderedProminent).padding(.trailing,6)
            } else {
                if session.document.canvas.width < 620 {
                    // Keep output actions visible; all tools and history remain reachable from the native menu.
                    Menu {
                        ForEach(EditingTool.allCases) { tool in
                            Button { select(tool) } label: {
                                Label(tool.title,systemImage:session.tool == tool ? "checkmark" : tool.symbol)
                            }
                        }
                        Divider()
                        Button(V2L("撤销")) { undo() }.disabled(!session.document.canUndo)
                        Button(V2L("重做")) { redo() }.disabled(!session.document.canRedo)
                        Button { float() } label: { Label(V2L("悬浮"), systemImage: "macwindow") }
                        if session.document.canvas.width < 240 { Divider(); viewActions }
                    } label: {
                        if session.document.canvas.width < 240 {
                            Text(zoomStatus).font(.system(size:11,weight:.medium,design:.monospaced)).frame(width:36,height:28)
                        } else { Image(systemName:session.tool?.symbol ?? "pencil.tip.crop.circle")
                            .font(.system(size:13)).frame(width:28,height:28)
                            .foregroundStyle(session.tool == nil ? Color.primary : Color.accentColor)
                            .background(session.tool == nil ? Color.clear : Color.accentColor.opacity(0.2),in:Circle())
                        }
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
                    .help(V2L("标注工具") + " · " + V2L("视图缩放")).accessibilityLabel(V2L("标注工具") + " · " + V2L("视图缩放"))
                    .accessibilityValue(session.tool?.title ?? V2L("未选择"))
                } else {
                    ForEach(EditingTool.allCases) { tool in
                        EditingIconButton(symbol:tool.symbol,glyph:tool == .text ? "T" : nil,label:tool.title,
                            help:tool == .arrow ? V2L("点击已有箭头可选择、移动和修改样式。") : tool == .number ? V2L("点击放置编号；选择已有编号可移动、修改样式或按 Delete 删除。") : tool == .redaction ? V2L("不透明黑色覆盖，始终显示在其他标注上方。") : tool == .highlight ? V2L("固定35%透明度，叠色突出内容。") : nil,selected:session.tool == tool) { select(tool) }
                        .accessibilityValue(session.tool == tool ? V2L("已选择") : V2L("未选择"))
                    }
                    Divider().frame(height:16)
                    EditingIconButton(symbol:"arrow.uturn.backward",label:V2L("撤销"),help:V2L("撤销 ⌘Z"),enabled:session.document.canUndo,action:undo)
                    EditingIconButton(symbol:"arrow.uturn.forward",label:V2L("重做"),help:V2L("重做 ⇧⌘Z"),enabled:session.document.canRedo,action:redo)
                }
                Divider().frame(height:16)
                if session.document.canvas.width >= 240 {
                Menu { viewActions } label: {
                    Text(zoomStatus)
                        .font(.system(size:11,weight:.medium,design:.monospaced)).frame(height:28)
                }
                .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
                .help(V2L("适配选区") + " ⌘2 · " + V2L("重置视图") + " ⌘0\n" + V2L("按住空格拖动平移") + "\n" + V2L("缩放相对于原始视图；不改变导出尺寸。"))
                .accessibilityLabel(V2L("视图缩放"))
                .accessibilityValue(zoomStatus)
                }
                if session.document.canvas.width >= 620 {
                    EditingIconButton(symbol:"macwindow",label:V2L("悬浮"),help:V2L("悬浮到屏幕最上层 ⌘F"),action:float)
                }
                EditingIconButton(symbol:"square.and.arrow.down",label:V2L("保存"),help:V2L("保存 PNG ⌘S"),action:save)
                EditingIconButton(symbol:"doc.on.doc",label:V2L("复制"),help:V2L("复制截图 ⌘C"),prominent:true,action:copy)
            }
        }
        .padding(.horizontal,6).frame(height:36).fixedSize(horizontal:true,vertical:false)
        .modifier(EditingSurface())
        .environment(\.locale,Locale(identifier:localization.english ? "en" : "zh-Hans"))
    }
    private var zoomStatus: String { "\(Int((session.viewport.scale * 100).rounded()))%" }
    @ViewBuilder private var viewActions: some View {
        Button(V2L("适配选区") + "  ⌘2",action:fitView)
        Button(V2L("重置视图") + "  ⌘0",action:resetView)
        Divider()
        Text(V2L("按住空格拖动平移"))
    }
    private func select(_ tool:EditingTool) {
        guard finishText() else { return }; session.tool = session.tool == tool ? nil : tool
    }
    private func undo() { guard finishText() else { return }; session.document.undo() }
    private func redo() { guard finishText() else { return }; session.document.redo() }
}

/// 28pt circular icon button used by the capture toolbar.
private struct EditingIconButton: View {
    let symbol: String
    var glyph: String?
    let label: String
    var help: String?
    var selected = false
    var prominent = false
    var enabled = true
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action:action) {
            Group {
                if let glyph { Text(glyph).font(.system(size:15,weight:.semibold)) }
                else { Image(systemName:symbol).font(.system(size:13,weight:.regular)) }
            }
                // Only the main action (copy) is a filled accent circle; a chosen tool is a tinted circle with an accent glyph.
                .foregroundStyle(prominent ? Color.white : (selected ? Color.accentColor : Color.primary))
                .frame(width:V2Design.iconButton,height:V2Design.iconButton)
                .background(prominent ? Color.accentColor : (selected ? Color.accentColor.opacity(0.2) : (hovering ? Color.primary.opacity(0.1) : .clear)),in:Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help ?? label).accessibilityLabel(label)
    }
}

struct EditingOptions: View {
    @State private var continuousStyleToken: EditingSession.StyleEditToken?
    @ObservedObject var session: EditingSession
    let colorPanel: EditingColorPanel
    @ObservedObject private var localization = V2Localization.shared
    var body: some View {
        HStack(spacing:12) {
            if let tool = session.tool {
                if tool == .highlight {
                    Text("35%").monospacedDigit().foregroundStyle(.secondary)
                    EditingColorWell(session:session,panel:colorPanel).frame(width:44,height:24)
                } else if tool == .blur {
                    Text(V2L("范围"))
                    Slider(value:$session.style.brushSize,in:8...60).frame(width:140).accessibilityLabel(V2L("模糊画笔直径"))
                    Text("\(Int(session.style.brushSize.rounded()))pt").monospacedDigit().foregroundStyle(.secondary).frame(width:42,alignment:.trailing)
                } else if tool != .redaction {
                    if tool == .text || tool == .number {
                        if session.document.canvas.width >= 300 { Text(V2L("字号")) }
                        EditingStyleNumberField(session:session,key:\.fontSize,range:8...96,label:V2L("字号")).frame(width:44,height:22)
                        if session.document.canvas.width >= 300 {
                            Stepper(V2L("字号"),value:styleBinding(\.fontSize),in:8...96,step:1).labelsHidden()
                        }
                    } else if tool == .arrow && session.document.canvas.width < 300 {
                        EditingStyleNumberField(session:session,key:\.width,range:1...20,label:V2L("线条粗细")).frame(width:44,height:22)
                    } else {
                        Text(V2L("粗细"))
                        let context = session.captureStyleContext()
                        Slider(value:styleBinding(\.width),in:1...20,onEditingChanged:{ editing in
                            if editing { continuousStyleToken = session.beginStyleEditing(context:context) }
                            else if let token = continuousStyleToken { session.finishStyleEditing(token); continuousStyleToken = nil }
                        }).frame(width:140).accessibilityLabel(V2L("线条粗细"))
                        Text("\(Int(session.effectiveStyle.width.rounded()))pt").monospacedDigit().foregroundStyle(.secondary).frame(width:36,alignment:.trailing)
                    }
                    EditingColorWell(session:session,panel:colorPanel).frame(width:44,height:24)
                    if tool == .rectangle || tool == .ellipse { Toggle(V2L("填充"),isOn:$session.style.filled).toggleStyle(.switch).fixedSize() }
                }
            }
        }
        .font(.callout).padding(.horizontal,12).frame(height:36).fixedSize(horizontal:true,vertical:false)
        .modifier(EditingSurface())
        .id(session.styleControlID)
        .disabled(session.isEditingText)
        .environment(\.locale,Locale(identifier:localization.english ? "en" : "zh-Hans"))
        .help(session.tool == .text ? V2L("单击选择文字，拖动移动；双击或按回车编辑；Command+回车提交，Esc取消。") : session.tool == .number ? V2L("点击放置编号；选择已有编号可移动、修改样式或按 Delete 删除。") : session.tool == .blur ? V2L("高斯模糊是视觉效果，不适用于安全隐藏敏感内容。") : session.tool == .highlight ? V2L("固定35%透明度，叠色突出内容。") : V2L("工具选项"))
    }
    private func styleBinding(_ key:WritableKeyPath<EditingStyle,CGFloat>) -> Binding<CGFloat> {
        let context = session.captureStyleContext()
        return Binding(get:{ session.effectiveStyle[keyPath:key] },set:{ value in
            var next = session.effectiveStyle; next[keyPath:key] = value
            if let token = continuousStyleToken { _ = session.updateStyle(next,token:token) }
            else { _ = session.setEffectiveStyle(next,context:context) }
        })
    }
}

private struct EditingSurface: ViewModifier {
    func body(content:Content) -> some View {
        content.v2GlassBackground(in:Capsule()).shadow(color:.black.opacity(0.18),radius:6,y:2)
    }
}
