import Foundation
import Testing
import TrayletCore
import AppKit
@testable import TrayletApp

@MainActor struct CaptureTests {
    @Test func cancelledCaptureCannotReplaceANewerFrameAndRepeatedStartIsRejected() async throws {
        let source = DelayedFrames()
        let session = V2CaptureSession(source: source, timeoutNanoseconds: 5_000_000_000)
        let target = V2CaptureTarget(displayID: 1, logicalSize: CGSize(width: 100, height: 80), pixelWidth: 200, pixelHeight: 160)
        var results: [String] = []
        #expect(session.start(target) { result in results.append((try? result.get()) == nil ? "cancelled" : "old") })
        #expect(!session.start(target) { _ in results.append("duplicate") })
        await settle()
        session.cancel()
        #expect(results == ["cancelled"] && !session.isBusy)
        #expect(session.start(target) { result in results.append((try? result.get()) == nil ? "error" : "new") })
        await settle()
        let image = try fixture()
        source.resolve(0, image: image); await settle()
        #expect(results == ["cancelled"] && session.isBusy)
        source.resolve(1, image: image); await settle()
        #expect(results == ["cancelled", "new"] && !session.isBusy)
    }

    @Test func timeoutClearsBusyStateAndLateFrameIsIgnored() async throws {
        let source = DelayedFrames()
        let deadline = ControlledDeadline()
        let session = V2CaptureSession(source: source, waitForDeadline: { _ in await deadline.wait() })
        let target = V2CaptureTarget(displayID: 1, logicalSize: CGSize(width: 10, height: 10), pixelWidth: 20, pixelHeight: 20)
        var calls = 0
        _ = session.start(target) { _ in calls += 1 }
        await deadline.ready()
        deadline.fire(); await settle()
        #expect(!session.isBusy && calls == 1)
        source.resolve(0, image: try fixture()); await settle()
        #expect(calls == 1)
    }
    private func settle() async { for _ in 0..<10 { await Task.yield() } }
    private func fixture() throws -> RasterImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        return try RasterImage(pngData: rep.representation(using: .png, properties: [:])!)
    }
}

@MainActor private final class ControlledDeadline {
    private var blocked: CheckedContinuation<Void, Never>?
    private var readiness: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation in blocked = continuation; readiness?.resume(); readiness = nil } }
    func ready() async { if blocked != nil { return }; await withCheckedContinuation { readiness = $0 } }
    func fire() { blocked?.resume(); blocked = nil }
}

@MainActor private final class DelayedFrames: V2ScreenCapturing {
    private var pending: [CheckedContinuation<V2Capture, any Error>?] = []
    func capture(_ target: V2CaptureTarget) async throws -> V2Capture {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func resolve(_ index: Int, image: RasterImage) {
        guard index < pending.count, let continuation = pending[index] else { return }
        pending[index] = nil; continuation.resume(returning: V2Capture(image: image))
    }
}
