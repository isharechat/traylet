import Foundation
import Testing
@testable import TrayletApp

struct ScrollPixelBufferTests {
    @Test func malformedDimensionsAndPixelCountsAreRejectedWithoutMultiplicationOverflow() {
        for (width, height, count) in [(0, 1, 4), (1, 0, 4), (-1, 1, 4), (2, 2, 4), (Int.max, 2, 0)] {
            #expect(throws: ScrollStitchFailure.invalidFrame) {
                try ScrollPixelBuffer(width: width, height: height, rgba: Data(repeating: 0, count: count))
            }
        }
    }
}
