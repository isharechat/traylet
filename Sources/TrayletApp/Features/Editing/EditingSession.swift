import AppKit
import Combine
import TrayletCore

@MainActor final class EditingSession: ObservableObject {
    let image: RasterImage
    @Published var document: EditingDocument
    @Published var viewport = EditingViewport()
    @Published var tool: EditingTool? {
        didSet {
            if tool != oldValue { finishStyleEditing(); document.selectMark(nil); styleGeneration &+= 1 }
        }
    }
    @Published var isEditingText = false
    @Published var style = EditingStyle()
    struct StyleContext: Equatable {
        fileprivate let target: UUID?
        fileprivate let tool: EditingTool?
        fileprivate let revision: UInt64
        fileprivate let generation: UInt64
    }
    struct StyleEditToken: Equatable { fileprivate let id: UUID }
    private struct StyleEdit {
        var token: StyleEditToken
        var context: StyleContext
        var originalDefault: EditingStyle
        var objectToken: EditingDocument.ObjectEditToken?
    }
    private var styleGeneration: UInt64 = 0
    private var styleEdit: StyleEdit?
    var styleControlID: String {
        (tool?.rawValue ?? "none") + ":" + (document.selectedMark?.tool == tool ? document.selectedMarkID?.uuidString ?? "default" : "default")
    }
    var effectiveStyle: EditingStyle {
        if let selected = document.selectedMark, selected.tool == tool { return selected.style }
        return style
    }
    func captureStyleContext() -> StyleContext {
        StyleContext(target:document.selectedMark?.tool == tool ? document.selectedMarkID : nil,
                     tool:tool,revision:document.objectContextRevision,generation:styleGeneration)
    }
    private func matches(_ context:StyleContext) -> Bool { context == captureStyleContext() }
    func selectObject(_ id:UUID?) {
        finishStyleEditing(); document.selectMark(id); styleGeneration &+= 1
    }
    @discardableResult func setEffectiveStyle(_ value:EditingStyle,context:StyleContext) -> Bool {
        guard let token = beginStyleEditing(context:context) else { return false }
        let changed = updateStyle(value,token:token); finishStyleEditing(token); return changed
    }
    func beginStyleEditing(context:StyleContext) -> StyleEditToken? {
        guard matches(context), !isEditingText, !document.isMovingObject else { return nil }
        finishStyleEditing()
        let currentContext = captureStyleContext()
        let token = StyleEditToken(id:UUID())
        var objectToken: EditingDocument.ObjectEditToken?
        if context.target != nil {
            objectToken = document.beginObjectEdit(.style)
            guard objectToken != nil else { return nil }
        }
        styleEdit = StyleEdit(token:token,context:currentContext,originalDefault:style,objectToken:objectToken)
        return token
    }
    @discardableResult func updateStyle(_ value:EditingStyle,token:StyleEditToken) -> Bool {
        guard let edit = styleEdit, edit.token == token else { return false }
        if let objectToken = edit.objectToken {
            guard document.isObjectEditActive(objectToken) else { return false }
            return document.styleObject(objectToken,style:value)
        }
        guard matches(edit.context) else { return false }
        var next = value
        next.fontSize = value.fontSize.isFinite ? max(8,min(96,value.fontSize)) : style.fontSize
        next.width = value.width.isFinite ? max(1,min(20,value.width)) : style.width
        guard next != style else { return false }; style = next; return true
    }
    func finishStyleEditing(_ token:StyleEditToken? = nil) {
        guard let edit = styleEdit, token == nil || edit.token == token else { return }
        styleEdit = nil
        if let objectToken = edit.objectToken { _ = document.commitObjectEdit(objectToken) }
        styleGeneration &+= 1
    }
    func isStyleEditing(_ token:StyleEditToken) -> Bool {
        guard let edit = styleEdit, edit.token == token else { return false }
        if let objectToken = edit.objectToken { return document.isObjectEditActive(objectToken) }
        return matches(edit.context)
    }
    func cancelStyleEditing(_ token:StyleEditToken? = nil) {
        guard let edit = styleEdit, token == nil || edit.token == token else { return }
        styleEdit = nil
        if let objectToken = edit.objectToken {
            if document.isObjectEditActive(objectToken) { document.cancelObjectEdit() }
        } else if styleGeneration == edit.context.generation { style = edit.originalDefault }
        styleGeneration &+= 1
    }
    func invalidateStyleEditing() { cancelStyleEditing(); styleGeneration &+= 1 }
    func didEndTextEditing() {
        if !isEditingText, messageSource == "请先完成文字输入。" { messageSource = "" }
    }
    func didEndObjectMove() {
        if !document.isMovingObject, messageSource == "请先完成标注移动。" { messageSource = "" }
    }
    /// Output finishes accepted style changes, but never exports an unfinished object move.
    @discardableResult func prepareOutput() -> Bool {
        guard !isEditingText else { message = "请先完成文字输入。"; return false }
        guard !document.isMovingObject else { message = "请先完成标注移动。"; return false }
        didEndObjectMove(); finishStyleEditing(); return true
    }
    @Published private var messageSource = ""
    var message: String {
        get { V2L(messageSource) }
        set { messageSource = newValue }
    }
    private let writer: any ImageOutputWriting
    private let decoded: CGImage?
    private(set) lazy var sourceImage: CGImage? = decoded ?? EditingRenderer.decode(image)

    init(image:RasterImage,decoded:CGImage? = nil,canvas:CGSize,fullScreen:Bool,writer:any ImageOutputWriting) {
        self.image = image; document = EditingDocument(canvas:canvas,imageSize:CGSize(width:image.width,height:image.height),fullScreen:fullScreen); self.writer = writer
        self.decoded = decoded.flatMap { $0.width == image.width && $0.height == image.height ? $0 : nil }
    }
    func composite(preview:EditingMark? = nil) throws -> RasterImage {
        guard let sourceImage else { return try EditingRenderer.render(image,document:document,preview:preview) }
        return try EditingRenderer.encode(EditingRenderer.compose(sourceImage,document:document,preview:preview))
    }
    /// Decoded display composite for live drawing; the PNG export path stays in `composite`.
    func compositeImage(preview:EditingMark? = nil) -> CGImage? {
        sourceImage.flatMap { try? EditingRenderer.compose($0,document:document,preview:preview) }
    }
    private var blurredCache: (version:UInt64,image:CGImage)?
    func blurredSourceImage() -> CGImage? {
        if let cached = blurredCache, cached.version == document.blurSourceVersion { return cached.image }
        guard let sourceImage, let result = try? EditingRenderer.composeBlurredSource(sourceImage,document:document) else { return nil }
        blurredCache = (document.blurSourceVersion,result); return result
    }
    @discardableResult func copy() -> Bool {
        guard prepareOutput() else { return false }
        do {
            switch writer.copyImage(try composite()) {
            case .copied: message = "已复制。"; return true
            case .changed: message = "剪贴板已变化；编辑已保留，请重试。"
            case .failed: message = "复制失败，剪贴板可能已清空；编辑已保留。"
            }
        } catch { message = "无法合成截图；编辑已保留。" }
        return false
    }
    @discardableResult func save(to url:URL?) -> Bool {
        guard let url, prepareOutput() else { return false }
        do { try composite().pngData.write(to:url,options:.atomic); message = "已保存。"; return true }
        catch { message = "保存失败；编辑已保留，请选择其他位置重试。"; return false }
    }
}
