import AppKit
import Testing
@testable import TrayletApp

struct FloatingImageZoomTests {
    @Test func clampedSizeBoundsAndRejectsNonFinite() {
        #expect(FloatingImageZoom.clampedSize(CGSize(width: 10, height: 10)) == FloatingImageZoom.minimumSize)
        #expect(FloatingImageZoom.clampedSize(CGSize(width: 99_999, height: 99_999)) == FloatingImageZoom.maximumSize)
        #expect(FloatingImageZoom.clampedSize(CGSize(width: 400, height: 300)) == CGSize(width: 400, height: 300))
        #expect(FloatingImageZoom.clampedSize(CGSize(width: CGFloat.nan, height: CGFloat.infinity)) == FloatingImageZoom.minimumSize)
    }
}
