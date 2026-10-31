import CoreGraphics

/// Display-only mapping. Canvas points and exported image pixels never depend on this value.
struct EditingViewport: Equatable {
    private(set) var scale: CGFloat = 1
    private(set) var offset = CGPoint.zero

    func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y)
    }
    func canvasPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
    }
    func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(origin: viewPoint(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }
    mutating func reset() { self = Self() }
    mutating func fit(_ selection: CGRect, in available: CGRect, canvas: CGSize) {
        guard selection.width > 0, selection.height > 0, available.width > 0, available.height > 0,
              [selection.minX, selection.minY, selection.width, selection.height,
               available.minX, available.minY, available.width, available.height].allSatisfy(\.isFinite) else { return }
        scale = max(0.25, min(8, min(available.width / selection.width, available.height / selection.height)))
        offset = CGPoint(x: available.midX - selection.midX * scale, y: available.midY - selection.midY * scale)
    }
    /// Leave at least 64pt of the image visible on each axis, even after a very large drag.
    mutating func pan(by delta: CGSize, in bounds: CGRect, canvas: CGSize) {
        guard [delta.width, delta.height, bounds.width, bounds.height, canvas.width, canvas.height].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0, canvas.width > 0, canvas.height > 0 else { return }
        let width = canvas.width * scale, height = canvas.height * scale
        let visibleX = min(64, min(width, bounds.width)), visibleY = min(64, min(height, bounds.height))
        offset.x = max(bounds.minX + visibleX - width, min(bounds.maxX - visibleX, offset.x + delta.width))
        offset.y = max(bounds.minY + visibleY - height, min(bounds.maxY - visibleY, offset.y + delta.height))
    }
}
