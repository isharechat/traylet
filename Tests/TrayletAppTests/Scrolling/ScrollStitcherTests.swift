import Foundation
import Testing
@testable import TrayletApp

struct ScrollStitcherTests {
    private func configuration(_ direction: ScrollDirection = .down) -> ScrollStitchConfiguration {
        var value = ScrollStitchConfiguration()
        value.direction = direction
        value.minimumOverlapRows = 2
        return value
    }

    private func original(width: Int = 3, rows: Int = 30) throws -> ScrollPixelBuffer {
        var bytes = Data()
        for y in 0..<rows {
            for x in 0..<width {
                bytes.append(contentsOf: [UInt8(y % 251), UInt8(x % 251), UInt8((y * 13 + x * 7) % 251), 255])
            }
        }
        return try ScrollPixelBuffer(width: width, height: rows, rgba: bytes)
    }

    private func crop(_ image: ScrollPixelBuffer, _ rows: Range<Int>) throws -> ScrollPixelBuffer {
        try ScrollPixelBuffer(width: image.width, height: rows.count,
                              rgba: image.rgba.subdata(in: rows.lowerBound * image.width * 4..<rows.upperBound * image.width * 4))
    }

    @Test func firstFrameIsRetainedExactlyAndEmptyBuilderHasNoImage() throws {
        var sut = try ScrollStitcher(configuration: configuration())
        #expect(try sut.image() == nil)
        let input = try original(rows: 8)
        #expect(try sut.append(input) == .accepted(newRows: 8, overlapRows: 0))
        #expect(try sut.image() == input)
        #expect(sut.progress.acceptedFrames == 1)
        #expect(sut.progress.width == 3)
        #expect(sut.progress.height == 8)
    }
}
