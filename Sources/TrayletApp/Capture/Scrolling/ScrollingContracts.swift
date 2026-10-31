import Foundation

/// Normalized, immutable RGBA8 pixels. Future native adapters must normalize color space and layout before returning these.
struct ScrollPixelBuffer: Equatable, Sendable {
    let width: Int
    let height: Int
    let rgba: Data
    init(width: Int, height: Int, rgba: Data) throws {
        guard width > 0, height > 0, width <= 64_000_000 / height,
              rgba.count == width * height * 4 else { throw ScrollStitchFailure.invalidFrame }
        self.width = width; self.height = height; self.rgba = rgba
    }
}

enum ScrollDirection: Equatable, Sendable { case up, down }

struct ScrollStitchConfiguration: Equatable, Sendable {
    var direction: ScrollDirection = .down
    var minimumOverlapRows = 32
    /// Explicit stable bands, not automatic sticky-header detection. Each band must remain identical.
    var fixedHeaderRows = 0
    var fixedFooterRows = 0
    var maximumOutputHeight = 16_000
    var maximumOutputPixels = 16_000_000
    /// Application-owned pixel buffers, matching scratch and assembly headroom; not total process RSS.
    var maximumWorkingBytes = 256 * 1_024 * 1_024
}

enum ScrollStitchFailure: Error, Equatable, Sendable {
    case invalidFrame, invalidConfiguration, dimensionsChanged, fixedBandsChanged
    case noOverlap, ambiguousOverlap, outputLimit, memoryLimit
}

enum ScrollAppendResult: Equatable, Sendable {
    case accepted(newRows: Int, overlapRows: Int)
    case duplicate
}

struct ScrollStitchProgress: Equatable, Sendable {
    var acceptedFrames = 0
    var width = 0
    var height = 0
    var estimatedWorkingBytes = 0
}

/// Adapter-issued identity/geometry snapshot. This is not an implementation of front-window validation.
struct ScrollTargetStamp: Equatable, Sendable {
    let targetID: UUID
    let geometryRevision: UInt64
    let pixelWidth: Int
    let pixelHeight: Int
}

struct ScrollCapturedFrame: Sendable {
    let target: ScrollTargetStamp
    let pixels: ScrollPixelBuffer
}

/// No native adapter is shipped in this slice. Implementations must check cancellation and actual target immediately before side effects.
protocol ScrollCaptureDriving: Sendable {
    func capture(expected: ScrollTargetStamp) async throws -> ScrollCapturedFrame
    func scroll(_ direction: ScrollDirection, expected: ScrollTargetStamp) async throws
}
