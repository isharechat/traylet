import AppKit

/// Fixed window geometry. Image coordinates retain their aspect; narrow images use a letterboxed viewport.
@MainActor struct ImportedImagePresentation {
    let canvasSize: CGSize
    let contentSize: CGSize

    init?(imageSize:CGSize,availableFrame:CGRect) {
        guard [imageSize.width,imageSize.height,availableFrame.minX,availableFrame.minY,availableFrame.width,availableFrame.height].allSatisfy(\.isFinite),
              imageSize.width > 0, imageSize.height > 0 else { return nil }
        let chrome = NSWindow.frameRect(forContentRect:CGRect(x:0,y:0,width:180,height:160),styleMask:[.titled,.closable]).height - 160
        guard availableFrame.width >= 180, availableFrame.height >= 160 + chrome else { return nil }
        let marginX = min(16,max(0,(availableFrame.width-180)/2))
        let marginY = min(16,max(0,(availableFrame.height-160-chrome)/2))
        let maximum = CGSize(width:min(1100,availableFrame.width-2*marginX),height:min(760,availableFrame.height-2*marginY-chrome))
        let ratio = min(1,min(maximum.width/imageSize.width,maximum.height/imageSize.height))
        canvasSize = CGSize(width:imageSize.width*ratio,height:imageSize.height*ratio)
        contentSize = CGSize(width:max(180,canvasSize.width),height:max(160,canvasSize.height))
    }
}
