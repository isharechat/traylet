import AppKit
import Accelerate
import ImageIO
import TrayletCore
import UniformTypeIdentifiers

@MainActor enum EditingRenderer {
    static func decode(_ image: RasterImage) -> CGImage? {
        CGImageSourceCreateWithData(image.pngData as CFData,nil).flatMap { CGImageSourceCreateImageAtIndex($0,0,nil) }
    }
    static func render(_ image: RasterImage, document: EditingDocument, preview: EditingMark? = nil) throws -> RasterImage {
        guard let cgImage = decode(image) else { throw FeatureIssue.invalidInput(V2L("请先选择截图区域。")) }
        return try encode(compose(cgImage,document:document,preview:preview))
    }
    static func encode(_ result: CGImage) throws -> RasterImage {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else { throw FeatureIssue.unavailable(V2L("无法编码截图。")) }
        CGImageDestinationAddImage(destination,result,nil)
        guard CGImageDestinationFinalize(destination) else { throw FeatureIssue.unavailable(V2L("无法编码截图。")) }
        return try RasterImage(pngData:data as Data)
    }
    /// Crops the selection from an already decoded screenshot and draws the marks; no PNG round trip.
    static func compose(_ cgImage: CGImage, document: EditingDocument, preview: EditingMark? = nil) throws -> CGImage {
        try compose(cgImage,document:document,preview:preview,includeAnnotations:true)
    }
    /// A live canvas caches only the expensive blur layer, so highlight previews can remain below all foreground marks.
    static func composeBlurredSource(_ cgImage:CGImage,document:EditingDocument) throws -> CGImage {
        try compose(cgImage,document:document,preview:nil,includeAnnotations:false)
    }
    private static func compose(_ cgImage:CGImage,document:EditingDocument,preview:EditingMark?,includeAnnotations:Bool) throws -> CGImage {
        guard let selection = document.selection, document.canvas.width > 0, document.canvas.height > 0 else {
            throw FeatureIssue.invalidInput(V2L("请先选择截图区域。"))
        }
        let sx = CGFloat(cgImage.width)/document.canvas.width, sy = CGFloat(cgImage.height)/document.canvas.height
        guard let pixelRect = document.pixelBounds(imageSize: CGSize(width: cgImage.width, height: cgImage.height)),
              let cropped = cgImage.cropping(to:pixelRect),
              let context = CGContext(data:nil,width:cropped.width,height:cropped.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FeatureIssue.unavailable(V2L("无法合成截图。"))
        }
        context.draw(cropped,in:CGRect(x:0,y:0,width:cropped.width,height:cropped.height))
        context.saveGState()
        context.translateBy(x:0,y:CGFloat(cropped.height))
        context.scaleBy(x:CGFloat(cropped.width)/selection.width,y:-CGFloat(cropped.height)/selection.height)
        let bounds = CGRect(origin:.zero,size:selection.size)
        context.clip(to:bounds)
        // Blur only ever softens the screenshot itself: blurs run first on the bare pixels, then every shape,
        // line and text is drawn on top so annotation colors are never smeared or tinted by a blur.
        let marks = document.marks + (preview.map { [$0] } ?? [])
        for mark in marks where mark.tool == .blur { try draw(mark,in:context,bounds:bounds,scale:max(sx,sy)) }
        if includeAnnotations {
        for mark in marks where mark.tool == .highlight { try draw(mark,in:context,bounds:bounds,scale:max(sx,sy)) }
        for mark in marks where mark.tool != .blur && mark.tool != .highlight && mark.tool != .redaction { try draw(mark,in:context,bounds:bounds,scale:max(sx,sy)) }
        }
        context.restoreGState()
        // Redaction is the final, opaque pixel operation. Neither later annotations nor blur can expose it.
        context.setShouldAntialias(false)
        context.setBlendMode(.copy)
        context.setFillColor(CGColor(red:0,green:0,blue:0,alpha:1))
        for rect in includeAnnotations ? redactionPixelRects(document:document,imageSize:CGSize(width:cgImage.width,height:cgImage.height),preview:preview) : [] {
            context.fill(CGRect(x:rect.minX,y:CGFloat(cropped.height)-rect.maxY,width:rect.width,height:rect.height))
        }
        guard let result = context.makeImage() else { throw FeatureIssue.unavailable(V2L("无法合成截图。")) }
        return result
    }
    /// Vector marks for live display; blur needs pixels and is handled by `compose`.
    static func drawLive(_ mark: EditingMark, in context: CGContext, bounds: CGRect) {
        guard mark.tool != .blur && mark.tool != .redaction else { return }
        try? draw(mark,in:context,bounds:bounds,scale:1)
    }

    /// Use the same outward-rounded output pixels for the live overlay, including an in-progress rectangle.
    static func drawRedactionsLive(document:EditingDocument,imageSize:CGSize,preview:EditingMark?,in context:CGContext) {
        guard let selection = document.selection, let crop = document.pixelBounds(imageSize:imageSize), !crop.isEmpty else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.setShouldAntialias(false)
        context.setBlendMode(.copy)
        context.setFillColor(CGColor(red:0,green:0,blue:0,alpha:1))
        context.scaleBy(x:selection.width/crop.width,y:selection.height/crop.height)
        for rect in redactionPixelRects(document:document,imageSize:imageSize,preview:preview) { context.fill(rect) }
    }

    /// Top-left output pixel coordinates. Map against the original image scale and crop origin, never a stretched crop.
    private static func redactionPixelRects(document:EditingDocument,imageSize:CGSize,preview:EditingMark?) -> [CGRect] {
        guard let selection = document.selection, let crop = document.pixelBounds(imageSize:imageSize), !crop.isEmpty else { return [] }
        let sx = imageSize.width/document.canvas.width, sy = imageSize.height/document.canvas.height
        return (document.marks + (preview.map { [$0] } ?? [])).compactMap { mark in
            guard mark.tool == .redaction, let a = mark.points.first, let b = mark.points.last,
                  a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return nil }
            let local = CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y))
                .intersection(CGRect(origin:.zero,size:selection.size))
            guard !local.isEmpty else { return nil }
            let left = floor((selection.minX+local.minX)*sx)-crop.minX
            let top = floor((selection.minY+local.minY)*sy)-crop.minY
            let right = ceil((selection.minX+local.maxX)*sx)-crop.minX
            let bottom = ceil((selection.minY+local.maxY)*sy)-crop.minY
            return CGRect(x:left,y:top,width:right-left,height:bottom-top).intersection(CGRect(origin:.zero,size:crop.size))
        }
    }

    private static func draw(_ mark: EditingMark, in c: CGContext, bounds: CGRect, scale: CGFloat) throws {
        guard let a = mark.points.first, let b = mark.points.last else { return }
        c.saveGState(); defer { c.restoreGState() }
        let color = mark.style.color.cgColor
        c.setStrokeColor(color); c.setFillColor(color)
        c.setLineWidth(max(1,min(20,mark.style.width)))
        c.setLineCap(.round); c.setLineJoin(.round)
        let box = CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y))
        switch mark.tool {
        case .highlight:
            c.setBlendMode(.multiply)
            c.setFillColor(mark.style.color.withAlphaComponent(0.35).cgColor)
            c.fill(box)
        case .redaction:
            break // Applied after all other tools in output pixel coordinates.
        case .rectangle, .ellipse:
            if mark.tool == .rectangle { c.addRect(box) } else { c.addEllipse(in:box) }
            c.drawPath(using:mark.style.filled ? .fillStroke : .stroke)
        case .line, .arrow:
            c.move(to:a); c.addLine(to:b)
            if mark.tool == .arrow {
                let angle = atan2(b.y-a.y,b.x-a.x), length = 10+mark.style.width*2.5
                c.move(to:CGPoint(x:b.x-length*cos(angle-0.45),y:b.y-length*sin(angle-0.45)))
                c.addLine(to:b)
                c.addLine(to:CGPoint(x:b.x-length*cos(angle+0.45),y:b.y-length*sin(angle+0.45)))
            }
            c.strokePath()
        case .pencil:
            if mark.points.count == 1 { c.fillEllipse(in:CGRect(x:a.x-mark.style.width/2,y:a.y-mark.style.width/2,width:mark.style.width,height:mark.style.width)) }
            else { c.addLines(between:mark.points); c.strokePath() }
        case .number:
            let badge = EditingNumberBadge.bounds(mark)
            c.setFillColor(mark.style.color.withAlphaComponent(1).cgColor); c.fillEllipse(in:badge)
            let rgb = mark.style.color.usingColorSpace(.deviceRGB) ?? .systemRed
            let luminance = 0.2126*rgb.redComponent+0.7152*rgb.greenComponent+0.0722*rgb.blueComponent
            let attributes: [NSAttributedString.Key:Any] = [.font:EditingNumberBadge.font(mark),.foregroundColor:luminance > 0.6 ? NSColor.black : NSColor.white]
            let text = String(mark.number ?? 1) as NSString, size = text.size(withAttributes:attributes)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext:c,flipped:true)
            text.draw(at:CGPoint(x:badge.midX-size.width/2,y:badge.midY-size.height/2),withAttributes:attributes)
            NSGraphicsContext.restoreGraphicsState()
        case .text:
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext:c,flipped:true)
            let textBounds = EditingTextLayout.container(mark,in:bounds)
            (mark.text as NSString).draw(with:textBounds,options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:EditingTextLayout.font(mark),.foregroundColor:mark.style.color])
            NSGraphicsContext.restoreGraphicsState()
        case .blur:
            // Blur is applied to the current composite. No original-image metadata is exported.
            let diameter = max(8,min(60,mark.style.brushSize))
            let shape: CGPath
            if mark.points.count == 1 { shape = CGPath(ellipseIn:CGRect(x:a.x-diameter/2,y:a.y-diameter/2,width:diameter,height:diameter),transform:nil) }
            else {
                let line = CGMutablePath(); line.addLines(between:mark.points)
                shape = line.copy(strokingWithWidth:diameter,lineCap:.round,lineJoin:.round,miterLimit:1)
            }
            // Only the brushed area changes, so only it is convolved; the kernel still reads real neighbours outside it.
            let device = c.convertToDeviceSpace(shape.boundingBoxOfPath.intersection(bounds)).integral
                .intersection(CGRect(x:0,y:0,width:c.width,height:c.height))
            guard !device.isEmpty else { return }
            guard let inputData = c.data,
                  let output = CGContext(data:nil,width:Int(device.width),height:Int(device.height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),
                  let outputData = output.data else { throw FeatureIssue.unavailable(V2L("无法应用高斯模糊。")) }
            let sigma = max(2,min(60,mark.style.brushSize)/5)*scale
            let radius = Int(ceil(sigma*3))
            var kernel = (-radius...radius).map { Float(exp(-Double($0*$0)/(2*Double(sigma*sigma)))) }
            let total = kernel.reduce(0,+)
            kernel = kernel.map { $0/total }
            var src = vImage_Buffer(data:inputData,height:vImagePixelCount(c.height),width:vImagePixelCount(c.width),rowBytes:c.bytesPerRow)
            var dst = vImage_Buffer(data:outputData,height:vImagePixelCount(output.height),width:vImagePixelCount(output.width),rowBytes:output.bytesPerRow)
            // A bitmap context's device space is top-down, the same order as its rows.
            let roiX = vImagePixelCount(device.minX), roiY = vImagePixelCount(device.minY)
            let error = kernel.withUnsafeBufferPointer { k in
                vImageSepConvolve_ARGB8888(&src,&dst,nil,roiX,roiY,k.baseAddress,UInt32(k.count),k.baseAddress,UInt32(k.count),0,nil,vImage_Flags(kvImageEdgeExtend))
            }
            guard error == kvImageNoError, let result = output.makeImage() else { throw FeatureIssue.unavailable(V2L("无法应用高斯模糊。")) }
            let target = c.convertToUserSpace(device)
            c.addPath(shape); c.clip()
            c.translateBy(x:0,y:target.minY+target.maxY); c.scaleBy(x:1,y:-1)
            c.draw(result,in:target)
        }
    }
}
