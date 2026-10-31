import Foundation
import CoreGraphics

/// Coordinates are canvas points, top-left origin. Marks are relative to selection origin.
struct EditingDocument {
    enum Handle: CaseIterable { case northWest, north, northEast, east, southEast, south, southWest, west }
    let canvas: CGSize
    let imageSize: CGSize
    private var selectionWasDragged = false
    private(set) var selection: CGRect?
    private(set) var renderVersion: UInt64 = 0
    private(set) var blurSourceVersion: UInt64 = 0
    private(set) var marks: [EditingMark] = []
    private enum Edit { case insert(EditingMark, Int), remove(EditingMark, Int), replace(EditingMark, EditingMark, Int) }
    private var history: [Edit] = []
    private var future: [Edit] = []
    private(set) var nextNumber = 1
    private(set) var selectedMarkID: UUID?
    private(set) var objectContextRevision: UInt64 = 0
    var selectedMark: EditingMark? { marks.first { $0.id == selectedMarkID } }
    var selectedNumber: Int? { selectedMark?.number }
    enum ObjectEditKind { case move, style, text }
    struct ObjectEditToken: Equatable { fileprivate let id: UUID; fileprivate let target: UUID; fileprivate let revision: UInt64 }
    private struct ObjectEdit { var token: ObjectEditToken; var original: EditingMark; var kind: ObjectEditKind; var visibleTextLine: CGRect? }
    private var objectEdit: ObjectEdit?
    var isMovingObject: Bool { objectEdit?.kind == .move }
    var hasObjectEdit: Bool { objectEdit != nil }
    mutating func selectMark(_ id: UUID?) {
        cancelObjectEdit()
        let next = id.flatMap { id in marks.first { $0.id == id && ($0.tool == .number || $0.tool == .arrow || $0.tool == .text) }?.id }
        if next != selectedMarkID { selectedMarkID = next; objectContextRevision &+= 1 }
    }
    mutating func selectNumber(_ number: Int?) {
        selectMark(number.flatMap { n in marks.first { $0.number == n }?.id })
    }
    @MainActor mutating func beginObjectEdit(_ kind:ObjectEditKind) -> ObjectEditToken? {
        cancelObjectEdit()
        guard let mark = selectedMark else { return nil }
        objectContextRevision &+= 1
        let token = ObjectEditToken(id:UUID(),target:mark.id,revision:objectContextRevision)
        let visibleTextLine = kind == .move && mark.tool == .text
            ? selection.flatMap { EditingTextLayout.lines(mark,in:CGRect(origin:.zero,size:$0.size)).first } : nil
        objectEdit = ObjectEdit(token:token,original:mark,kind:kind,visibleTextLine:visibleTextLine)
        return token
    }
    private func validEdit(_ token:ObjectEditToken) -> ObjectEdit? {
        guard let edit = objectEdit, edit.token == token, selectedMarkID == token.target,
              objectContextRevision == token.revision, marks.contains(where:{ $0.id == token.target }) else { return nil }
        return edit
    }
    @MainActor @discardableResult mutating func moveObject(_ token:ObjectEditToken,totalCanvasDelta:CGSize) -> Bool {
        guard let edit = validEdit(token), edit.kind == .move, let crop = selection,
              totalCanvasDelta.width.isFinite, totalCanvasDelta.height.isFinite,
              valid(canvas),valid(imageSize), let first = edit.original.points.first else { return false }
        let box = edit.original.points.reduce(CGRect(origin:first,size:.zero)) { $0.union(CGRect(origin:$1,size:.zero)) }
        let sx = imageSize.width/canvas.width, sy = imageSize.height/canvas.height
        if edit.original.tool == .text,
           let line = edit.visibleTextLine {
            // Keep one currently visible nonblank line available for picking. Already clipped text
            // keeps its original zero-delta position; other tools retain their existing anchor bounds.
            let visibleWidth = line.width, visibleHeight = line.height
            let dx = max(ceil(stable(min(0,-line.maxX+visibleWidth)*sx)),
                         min(floor(stable(max(0,crop.width-line.minX-visibleWidth)*sx)),stable(totalCanvasDelta.width*sx).rounded()))/sx
            let dy = max(ceil(stable(min(0,-line.maxY+visibleHeight)*sy)),
                         min(floor(stable(max(0,crop.height-line.minY-visibleHeight)*sy)),stable(totalCanvasDelta.height*sy).rounded()))/sy
            var next = edit.original; next.points = next.points.map { CGPoint(x:$0.x+dx,y:$0.y+dy) }
            return replacePreview(next,token:token)
        }
        // Preserve already clipped anchors at zero delta; do not silently pull existing objects into the crop.
        let dx = max(ceil(stable(min(0,-box.minX)*sx)),min(floor(stable(max(0,crop.width-box.maxX)*sx)),stable(totalCanvasDelta.width*sx).rounded()))/sx
        let dy = max(ceil(stable(min(0,-box.minY)*sy)),min(floor(stable(max(0,crop.height-box.maxY)*sy)),stable(totalCanvasDelta.height*sy).rounded()))/sy
        var next = edit.original; next.points = next.points.map { CGPoint(x:$0.x+dx,y:$0.y+dy) }
        return replacePreview(next,token:token)
    }
    func isObjectEditActive(_ token:ObjectEditToken) -> Bool { validEdit(token) != nil }
    @discardableResult mutating func styleObject(_ token:ObjectEditToken,style:EditingStyle) -> Bool {
        guard let edit = validEdit(token), edit.kind == .style, let current = selectedMark else { return false }
        var next = current; next.style.color = style.color
        if next.tool == .number || next.tool == .text { next.style.fontSize = style.fontSize.isFinite ? max(8,min(96,style.fontSize)) : current.style.fontSize }
        if next.tool == .arrow { next.style.width = style.width.isFinite ? max(1,min(20,style.width)) : current.style.width }
        return replacePreview(next,token:token)
    }
    @discardableResult mutating func textObject(_ token:ObjectEditToken,text:String) -> Bool {
        guard let edit = validEdit(token), edit.kind == .text else { return false }
        var next = edit.original; next.text = text
        return replacePreview(next,token:token)
    }
    private mutating func replacePreview(_ mark:EditingMark,token:ObjectEditToken) -> Bool {
        guard validEdit(token) != nil, let index = marks.firstIndex(where:{ $0.id == token.target }), marks[index] != mark else { return false }
        marks[index] = mark; renderVersion &+= 1; return true
    }
    @discardableResult mutating func commitObjectEdit(_ token:ObjectEditToken) -> Bool {
        guard let edit = validEdit(token), let index = marks.firstIndex(where:{ $0.id == token.target }) else { return false }
        objectEdit = nil; objectContextRevision &+= 1
        guard marks[index] != edit.original else { return false }
        if edit.kind == .text && marks[index].text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            marks.remove(at:index); history.append(.remove(edit.original,index)); selectedMarkID = nil; renderVersion &+= 1
        } else { history.append(.replace(edit.original,marks[index],index)) }
        future.removeAll(); return true
    }
    mutating func cancelObjectEdit() {
        guard let edit = objectEdit else { return }
        objectEdit = nil; objectContextRevision &+= 1
        if let index = marks.firstIndex(where:{ $0.id == edit.original.id }), marks[index] != edit.original {
            marks[index] = edit.original; renderVersion &+= 1
        }
    }
    @MainActor @discardableResult mutating func nudgeSelectedObject(_ direction:NudgeDirection,accelerated:Bool = false) -> Bool {
        guard !hasObjectEdit, let token = beginObjectEdit(.move) else { return false }
        let step:CGFloat = accelerated ? 10 : 1
        let delta = CGSize(width:(direction == .left ? -step : direction == .right ? step : 0)*canvas.width/imageSize.width,
                           height:(direction == .up ? -step : direction == .down ? step : 0)*canvas.height/imageSize.height)
        _ = moveObject(token,totalCanvasDelta:delta); return commitObjectEdit(token)
    }
    private var customToolbar: CGPoint?
    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    mutating func append(_ input: EditingMark) {
        cancelObjectEdit()
        var mark = input
        guard !mark.points.isEmpty, mark.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
        // Rectangular area tools retain sub-point drags, but a click or a zero-area line covers nothing.
        if mark.tool == .redaction || mark.tool == .highlight {
            guard let first = mark.points.first, let last = mark.points.last,
                  first.x != last.x, first.y != last.y else { return }
        }
        if mark.tool == .text, let selection, let origin = mark.points.first {
            if mark.textWidth == nil || !mark.textWidth!.isFinite || mark.textWidth! <= 0 {
                mark.textWidth = max(1,selection.width-origin.x)
            }
        }
        if mark.tool == .number {
            guard nextNumber < Int.max else { return }
            mark.number = nextNumber; nextNumber += 1
        } else { mark.number = nil }
        history.append(.insert(mark,marks.count)); marks.append(mark)
        future.removeAll(); renderVersion &+= 1
        if mark.tool == .blur { blurSourceVersion &+= 1 }
        if mark.tool == .number || mark.tool == .arrow || mark.tool == .text { selectMark(mark.id) }
    }
    @discardableResult mutating func deleteSelectedNumber() -> Bool {
        guard selectedMark?.tool == .number else { return false }; return deleteSelectedMark()
    }
    @discardableResult mutating func deleteSelectedMark() -> Bool {
        cancelObjectEdit()
        guard let selectedMarkID, let index = marks.firstIndex(where:{ $0.id == selectedMarkID }) else { return false }
        let mark = marks.remove(at:index)
        history.append(.remove(mark,index)); future.removeAll(); selectMark(nil); renderVersion &+= 1
        return true
    }
    mutating func undo() {
        if hasObjectEdit { cancelObjectEdit(); return }
        objectContextRevision &+= 1
        guard let edit = history.popLast() else { return }
        invalidateBlur(for:edit)
        switch edit {
        case .insert(_,let index): marks.remove(at:index)
        case .remove(let mark,let index): marks.insert(mark,at:index)
        case .replace(let old,_,let index): marks[index] = old
        }
        selectNumber(nil); future.append(edit); renderVersion &+= 1
    }
    mutating func redo() {
        if hasObjectEdit { cancelObjectEdit(); return }
        objectContextRevision &+= 1
        guard let edit = future.popLast() else { return }
        invalidateBlur(for:edit)
        switch edit {
        case .insert(let mark,let index): marks.insert(mark,at:index)
        case .remove(_,let index): marks.remove(at:index)
        case .replace(_,let new,let index): marks[index] = new
        }
        selectNumber(nil); history.append(edit); renderVersion &+= 1
    }
    private mutating func invalidateBlur(for edit:Edit) {
        switch edit {
        case .insert(let mark,_), .remove(let mark,_):
            if mark.tool == .blur { blurSourceVersion &+= 1 }
        case .replace(let old,let new,_):
            if old.tool == .blur || new.tool == .blur { blurSourceVersion &+= 1 }
        }
    }
    mutating func dragToolbar(to point: CGPoint) { customToolbar = point }
    mutating func resetToolbar() { customToolbar = nil }
    func toolbarOrigin(size: CGSize) -> CGPoint {
        let r = selection ?? CGRect(origin: .zero, size: canvas)
        var p = customToolbar ?? CGPoint(x:r.maxX-size.width, y:r.maxY+10)
        if customToolbar == nil && p.y+size.height > canvas.height-4 { p.y = r.maxY-size.height-10 }
        return CGPoint(x:max(4,min(canvas.width-size.width-4,p.x)), y:max(4,min(canvas.height-size.height-4,p.y)))
    }
    func optionsOrigin(toolbar: CGRect, size: CGSize) -> CGPoint {
        let below = toolbar.maxY+8
        return CGPoint(x:max(4,min(canvas.width-size.width-4,toolbar.minX)), y:below+size.height <= canvas.height-4 ? below : max(4,toolbar.minY-size.height-8))
    }
    enum EscapeAction { case inputMethod, cancelText, close }
    enum NudgeDirection { case left, right, up, down }
    /// Selection edges are converted through a single stable, outward-covering pixel boundary.
    private func stable(_ value: CGFloat) -> CGFloat {
        let nearest = value.rounded()
        return abs(value-nearest) < 0.0000001 ? nearest : value
    }
    private func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
    func pixelBounds(imageSize: CGSize) -> CGRect? {
        guard let selection, !selection.isEmpty, valid(canvas), valid(imageSize) else { return nil }
        let sx = imageSize.width/canvas.width, sy = imageSize.height/canvas.height
        let left = floor(stable(selection.minX*sx)), top = floor(stable(selection.minY*sy))
        let right = ceil(stable(selection.maxX*sx)), bottom = ceil(stable(selection.maxY*sy))
        let result = CGRect(x:left,y:top,width:right-left,height:bottom-top)
            .intersection(CGRect(origin:.zero,size:imageSize))
        return result.isEmpty || result.isNull ? nil : result
    }
    private func canvasRect(_ pixels: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(x:pixels.minX*canvas.width/imageSize.width,y:pixels.minY*canvas.height/imageSize.height,
               width:pixels.width*canvas.width/imageSize.width,height:pixels.height*canvas.height/imageSize.height)
    }
    private func snapped(_ rect: CGRect) -> CGRect? {
        guard valid(canvas), valid(imageSize) else { return nil }
        let sx = imageSize.width/canvas.width, sy = imageSize.height/canvas.height
        let x = max(0,min(imageSize.width-1,floor(stable(rect.minX*sx))))
        let y = max(0,min(imageSize.height-1,floor(stable(rect.minY*sy))))
        let right = min(imageSize.width,max(x+1,ceil(stable(rect.maxX*sx))))
        let bottom = min(imageSize.height,max(y+1,ceil(stable(rect.maxY*sy))))
        return canvasRect(CGRect(x:x,y:y,width:right-x,height:bottom-y),imageSize:imageSize)
    }
    private mutating func updateSelection(_ next: CGRect?) {
        guard next != selection else { return }
        selection = next; renderVersion &+= 1; blurSourceVersion &+= 1
    }
    /// Integer source pixels keep both dimensions stable, including after hundreds of moves.
    @discardableResult mutating func nudgeSelection(_ direction: NudgeDirection, imageSize: CGSize,
                                                   accelerated: Bool = false, resizing: Bool = false) -> Bool {
        guard var pixels = pixelBounds(imageSize:imageSize) else { return false }
        let amount: CGFloat = accelerated ? 10 : 1
        let dx: CGFloat = direction == .left ? -amount : direction == .right ? amount : 0
        let dy: CGFloat = direction == .up ? -amount : direction == .down ? amount : 0
        if resizing {
            pixels.size.width = max(1,min(imageSize.width-pixels.minX,pixels.width+dx))
            pixels.size.height = max(1,min(imageSize.height-pixels.minY,pixels.height+dy))
        } else {
            pixels.origin.x = max(0,min(imageSize.width-pixels.width,pixels.minX+dx))
            pixels.origin.y = max(0,min(imageSize.height-pixels.height,pixels.minY+dy))
        }
        let next = canvasRect(pixels,imageSize:imageSize)
        guard next != selection else { return false }
        updateSelection(next); return true
    }
    static func escapeAction(isEditingText: Bool, hasMarkedText: Bool) -> EscapeAction {
        hasMarkedText ? .inputMethod : (isEditingText ? .cancelText : .close)
    }

    init(canvas: CGSize, imageSize: CGSize? = nil, fullScreen: Bool = false) {
        self.canvas = canvas; self.imageSize = imageSize ?? canvas
        if fullScreen { selection = CGRect(origin:.zero,size:canvas) }
    }
    mutating func select(from start: CGPoint, to end: CGPoint) {
        selectLive(from:start,to:end); _ = finishSelection()
    }
    /// Live geometry follows the pointer; release covers its real fractional pixel edges.
    mutating func selectLive(from start: CGPoint, to end: CGPoint) {
        guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { return }
        let a = clamp(start), b = clamp(end)
        selectionWasDragged = start != end
        updateSelection(CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y)))
    }
    mutating func discardUnfinishedSelection() {
        selectionWasDragged = false; updateSelection(nil)
    }
    @discardableResult mutating func finishSelection() -> Bool {
        guard selectionWasDragged, let r = selection, let next = snapped(r) else {
            discardUnfinishedSelection(); return false
        }
        selectionWasDragged = false; updateSelection(next); return true
    }
    mutating func moveSelection(by delta: CGSize) {
        guard let r = selection, var pixels = pixelBounds(imageSize:imageSize),
              delta.width.isFinite, delta.height.isFinite else { return }
        pixels.origin.x = max(0,min(imageSize.width-pixels.width,stable((r.minX+delta.width)*imageSize.width/canvas.width).rounded()))
        pixels.origin.y = max(0,min(imageSize.height-pixels.height,stable((r.minY+delta.height)*imageSize.height/canvas.height).rounded()))
        updateSelection(canvasRect(pixels,imageSize:imageSize))
    }
    mutating func resizeSelection(_ handle: Handle, to point: CGPoint) {
        guard let r = pixelBounds(imageSize:imageSize), point.x.isFinite, point.y.isFinite else { return }
        let p = clamp(point)
        let px = stable(p.x*imageSize.width/canvas.width), py = stable(p.y*imageSize.height/canvas.height)
        var x = r.minX, y = r.minY, right = r.maxX, bottom = r.maxY
        if [.northWest,.west,.southWest].contains(handle) { x = min(floor(px),right-1) }
        if [.northEast,.east,.southEast].contains(handle) { right = max(ceil(px),x+1) }
        if [.northWest,.north,.northEast].contains(handle) { y = min(floor(py),bottom-1) }
        if [.southWest,.south,.southEast].contains(handle) { bottom = max(ceil(py),y+1) }
        updateSelection(canvasRect(CGRect(x:x,y:y,width:right-x,height:bottom-y),imageSize:imageSize))
    }
    func clamp(_ p: CGPoint) -> CGPoint { CGPoint(x:max(0,min(canvas.width,p.x)),y:max(0,min(canvas.height,p.y))) }
}
