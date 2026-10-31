import Foundation

struct ScrollStitcher: Sendable {
    init(configuration: ScrollStitchConfiguration) throws {}
    var progress = ScrollStitchProgress()
    mutating func append(_ frame: ScrollPixelBuffer) throws -> ScrollAppendResult { .duplicate }
    func image() throws -> ScrollPixelBuffer? { nil }
}
