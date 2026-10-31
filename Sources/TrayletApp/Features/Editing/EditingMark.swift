import AppKit

enum EditingTool: String, CaseIterable, Identifiable {
    case rectangle, ellipse, line, arrow, pencil, text, number, highlight, blur, redaction
    var id: String { rawValue }
    @MainActor var title: String {
        switch self {
        case .rectangle: V2L("矩形")
        case .ellipse: V2L("椭圆")
        case .line: V2L("线条")
        case .arrow: V2L("箭头")
        case .pencil: V2L("铅笔")
        case .text: V2L("文字")
        case .number: V2L("编号")
        case .highlight: V2L("高亮")
        case .blur: V2L("高斯模糊")
        case .redaction: V2L("遮挡")
        }
    }
    var symbol: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .pencil: "pencil.tip"
        case .text: "textformat"
        case .number: "1.circle"
        case .highlight: "highlighter"
        case .blur: "drop.halffull"
        case .redaction: "rectangle.fill"
        }
    }
}

struct EditingStyle: Equatable {
    var color: NSColor = .systemRed
    var width: CGFloat = 4
    var filled = false
    var fontSize: CGFloat = 24
    /// Diameter in canvas points; Gaussian blur is a visual effect, not redaction.
    var brushSize: CGFloat = 22
}
struct EditingMark: Identifiable, Equatable {
    let id = UUID()
    var tool: EditingTool
    var points: [CGPoint]
    var style = EditingStyle()
    var text = ""
    var number: Int?
    /// Frozen wrapping width in canvas points; moving text does not reflow it.
    var textWidth: CGFloat?
}

/// The live renderer, export and picking share the same badge geometry and font.
@MainActor enum EditingNumberBadge {
    static func font(_ mark:EditingMark) -> NSFont {
        .monospacedDigitSystemFont(ofSize:max(8,min(96,mark.style.fontSize)),weight:.semibold)
    }
    static func bounds(_ mark:EditingMark) -> CGRect {
        guard let center = mark.points.first else { return .zero }
        let font = font(mark)
        let textSize = (String(mark.number ?? 1) as NSString).size(withAttributes:[.font:font])
        let diameter = max(font.pointSize*1.6,textSize.width+font.pointSize*0.8)
        return CGRect(x:center.x-diameter/2,y:center.y-diameter/2,width:diameter,height:diameter)
    }
}

@MainActor enum EditingObjectGeometry {
    static func arrowSegments(_ mark:EditingMark) -> [(CGPoint,CGPoint)] {
        guard let a = mark.points.first, let b = mark.points.last else { return [] }
        let angle = atan2(b.y-a.y,b.x-a.x), length = 10+mark.style.width*2.5
        return [(a,b),(CGPoint(x:b.x-length*cos(angle-0.45),y:b.y-length*sin(angle-0.45)),b),
                (b,CGPoint(x:b.x-length*cos(angle+0.45),y:b.y-length*sin(angle+0.45)))]
    }
    static func bounds(_ mark:EditingMark) -> CGRect {
        if mark.tool == .number { return EditingNumberBadge.bounds(mark) }
        let points = arrowSegments(mark).flatMap { [$0.0,$0.1] }
        guard let first = points.first else { return .zero }
        return points.reduce(CGRect(origin:first,size:.zero)) { $0.union(CGRect(origin:$1,size:.zero)) }.insetBy(dx:-mark.style.width/2,dy:-mark.style.width/2)
    }
    static func contains(_ point:CGPoint,mark:EditingMark,viewScale:CGFloat) -> Bool {
        if mark.tool == .number {
            let b = EditingNumberBadge.bounds(mark)
            return hypot(point.x-b.midX,point.y-b.midY) <= b.width/2
        }
        guard mark.tool == .arrow else { return false }
        return arrowSegments(mark).contains { a,b in
            let dx = b.x-a.x, dy = b.y-a.y, lengthSquared = dx*dx+dy*dy
            let t = lengthSquared > 0 ? max(0,min(1,((point.x-a.x)*dx+(point.y-a.y)*dy)/lengthSquared)) : 0
            return hypot(point.x-a.x-t*dx,point.y-a.y-t*dy) <= max(mark.style.width/2,6/max(0.25,viewScale))
        }
    }
}

/// Font, wrapping bounds and visible line hits shared with the renderer's text drawing.
@MainActor enum EditingTextLayout {
    static func font(_ mark:EditingMark) -> NSFont { .systemFont(ofSize:max(8,min(96,mark.style.fontSize)),weight:.semibold) }
    static func container(_ mark:EditingMark,in bounds:CGRect) -> CGRect {
        guard let p = mark.points.first else { return .zero }
        return CGRect(x:p.x,y:p.y,width:max(0,mark.textWidth ?? (bounds.maxX-p.x)),height:max(0,bounds.maxY-p.y))
    }
    static func lines(_ mark:EditingMark,in bounds:CGRect) -> [CGRect] {
        let box = container(mark,in:bounds)
        guard box.width > 0, box.height > 0, !mark.text.isEmpty else { return [] }
        let storage = NSTextStorage(string:mark.text,attributes:[.font:font(mark)])
        let layout = NSLayoutManager(), container = NSTextContainer(size:box.size)
        container.lineFragmentPadding = 0; layout.addTextContainer(container); storage.addLayoutManager(layout)
        let glyphs = layout.glyphRange(for:container)
        var result:[CGRect] = []
        layout.enumerateLineFragments(forGlyphRange:glyphs) { _,used,_,range,_ in
            let characters = layout.characterRange(forGlyphRange:range,actualGlyphRange:nil)
            guard !(mark.text as NSString).substring(with:characters).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
            let rect = used.offsetBy(dx:box.minX,dy:box.minY).intersection(bounds)
            if !rect.isEmpty { result.append(rect) }
        }
        return result
    }
    static func bounds(_ mark:EditingMark,in bounds:CGRect) -> CGRect { lines(mark,in:bounds).reduce(.null) { $0.union($1) } }
    static func contains(_ point:CGPoint,mark:EditingMark,in bounds:CGRect) -> Bool { lines(mark,in:bounds).contains { $0.contains(point) } }
}
