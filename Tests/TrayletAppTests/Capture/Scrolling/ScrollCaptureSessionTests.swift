import Foundation
import Testing
@testable import TrayletApp

@MainActor struct ScrollCaptureSessionTests {
    @Test func cancellationDoesNotWaitForCaptureAndOldFrameCannotAffectANewerRun() async throws {
        let driver = HeldScrollDriver()
        let target = ScrollTargetStamp(targetID: UUID(), geometryRevision: 1, pixelWidth: 3, pixelHeight: 4)
        let sut = ScrollCaptureSession(driver: driver)
        var request = ScrollCaptureRequest(target: target)
        request.stitching.minimumOverlapRows = 2
        var outcomes: [ScrollCaptureOutcome] = []
        try #require(sut.start(request) { outcomes.append($0) })
        let duplicateStarted = try sut.start(request) { _ in Issue.record("duplicate start") }
        #expect(!duplicateStarted)
        await settle()
        let firstCalls = await driver.captureCount
        try #require(firstCalls == 1)
        sut.cancel(); await settle()
        #expect(!sut.state.isBusy && outcomes.count == 1)
        #expect(outcomes.first?.reason == .cancelled && outcomes.first?.image == nil)
        try #require(sut.start(request) { outcomes.append($0) })
        await settle()
        let secondCalls = await driver.captureCount
        try #require(secondCalls == 2)
        let frame = try ScrollPixelBuffer(width: 3, height: 4, rgba: Data(repeating: 255, count: 48))
        await driver.resolve(0, frame: ScrollCapturedFrame(target: target, pixels: frame)); await settle()
        #expect(sut.state.isBusy && sut.state.progress.capturedFrames == 0 && outcomes.count == 1)
        let scrolls = await driver.scrollCount
        #expect(scrolls == 0)
        sut.cancel(); await settle()
        await driver.resolve(1, frame: ScrollCapturedFrame(target: target, pixels: frame)); await settle()
        #expect(outcomes.count == 2 && !sut.state.isBusy)
    }
    @Test func deadlineCompletesWithoutWaitingForAnUncooperativeCapture() async throws {
        let driver = HeldScrollDriver(), clock = ScrollDeadlineClock()
        let target = ScrollTargetStamp(targetID: UUID(), geometryRevision: 1, pixelWidth: 3, pixelHeight: 4)
        let sut = ScrollCaptureSession(driver: driver, waitForDeadline: { _ in await clock.wait() })
        var request = ScrollCaptureRequest(target: target); request.stitching.minimumOverlapRows = 2
        var outcomes: [ScrollCaptureOutcome] = []
        try #require(sut.start(request) { outcomes.append($0) }); await settle()
        let calls = await driver.captureCount, deadlines = await clock.count
        try #require(calls == 1 && deadlines == 1)
        await clock.fire(0); await settle()
        #expect(!sut.state.isBusy && outcomes.count == 1 && outcomes.first?.reason == .timedOut)
        await driver.failAll(); await settle()
        let scrolls = await driver.scrollCount
        #expect(outcomes.count == 1 && scrolls == 0)
    }
    @Test func aChangedTargetIsRejectedBeforeMatchingOrScrolling() async throws {
        let driver = HeldScrollDriver()
        let target = ScrollTargetStamp(targetID: UUID(), geometryRevision: 1, pixelWidth: 3, pixelHeight: 4)
        let sut = ScrollCaptureSession(driver: driver)
        var request = ScrollCaptureRequest(target: target); request.stitching.minimumOverlapRows = 2
        try #require(sut.start(request) { _ in }); await settle()
        let calls = await driver.captureCount; try #require(calls == 1)
        let changed = ScrollTargetStamp(targetID: target.targetID, geometryRevision: 2, pixelWidth: 3, pixelHeight: 4)
        let pixels = try ScrollPixelBuffer(width: 3, height: 4, rgba: Data(repeating: 255, count: 48))
        await driver.resolve(0, frame: ScrollCapturedFrame(target: changed, pixels: pixels)); await settle()
        #expect(sut.state.outcome?.reason == .targetChanged && sut.state.progress.stitching.acceptedFrames == 0)
        let scrolls = await driver.scrollCount; #expect(scrolls == 0)
    }
    @Test func impossibleBudgetsAreRejectedBeforeInvokingTheDriver() async throws {
        let target = ScrollTargetStamp(targetID: UUID(), geometryRevision: 1, pixelWidth: 3, pixelHeight: 4)
        for field in 0..<4 {
            let driver = HeldScrollDriver()
            let checked = ScrollCaptureSession(driver: driver)
            var request = ScrollCaptureRequest(target: target); request.stitching.minimumOverlapRows = 2
            switch field {
            case 0: request.stitching.maximumOutputHeight = 3
            case 1: request.stitching.maximumOutputPixels = 11
            case 2: request.stitching.maximumWorkingBytes = 47
            default: request.maximumFrames = 0
            }
            #expect(throws: ScrollStitchFailure.invalidConfiguration) { try checked.start(request) { _ in } }
            await settle()
            let calls = await driver.captureCount; #expect(calls == 0)
            checked.cancel(); await driver.failAll(); await settle()
        }
    }
    private func settle() async { for _ in 0..<40 { await Task.yield() } }
}

private actor HeldScrollDriver: ScrollCaptureDriving {
    private var pending: [CheckedContinuation<ScrollCapturedFrame, any Error>?] = []
    private(set) var scrollCount = 0
    var captureCount: Int { pending.count }
    func capture(expected: ScrollTargetStamp) async throws -> ScrollCapturedFrame {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func scroll(_ direction: ScrollDirection, expected: ScrollTargetStamp) async throws { scrollCount += 1 }
    func resolve(_ index: Int, frame: ScrollCapturedFrame) {
        guard pending.indices.contains(index), let continuation = pending[index] else { return }
        pending[index] = nil; continuation.resume(returning: frame)
    }
    func failAll() {
        let waiting = pending; pending = pending.map { _ in nil }
        for continuation in waiting { continuation?.resume(throwing: ScrollStitchFailure.invalidFrame) }
    }
}

private actor ScrollDeadlineClock {
    private var waiting: [CheckedContinuation<Void, Never>?] = []
    var count: Int { waiting.count }
    func wait() async { await withCheckedContinuation { waiting.append($0) } }
    func fire(_ index: Int) {
        guard waiting.indices.contains(index), let continuation = waiting[index] else { return }
        waiting[index] = nil; continuation.resume()
    }
}
