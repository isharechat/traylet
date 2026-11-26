import Foundation
import Combine

struct ScrollCaptureRequest: Sendable {
    let target: ScrollTargetStamp
    var stitching = ScrollStitchConfiguration()
    var maximumFrames = 60
    var maximumDurationNanoseconds: UInt64 = 30_000_000_000
    var intervalNanoseconds: UInt64 = 150_000_000
    var duplicateLimit = 3
}

enum ScrollCaptureStopReason: Equatable, Sendable {
    case cancelled, userFinished, timedOut, frameLimit, noProgress, targetChanged, driverFailed
    case stitchFailed(ScrollStitchFailure)
}

struct ScrollCaptureProgress: Equatable, Sendable {
    var capturedFrames = 0
    var consecutiveDuplicates = 0
    var stitching = ScrollStitchProgress()
}

struct ScrollCaptureOutcome: Equatable, Sendable {
    let runID: UUID
    let reason: ScrollCaptureStopReason
    let progress: ScrollCaptureProgress
    let image: ScrollPixelBuffer?
}

enum ScrollCapturePhase: Sendable { case idle, capturing, matching, scrolling, stopping, finished }
struct ScrollCaptureState: Sendable {
    var runID: UUID?
    var phase: ScrollCapturePhase = .idle
    var progress = ScrollCaptureProgress()
    var outcome: ScrollCaptureOutcome?
    var isBusy: Bool { phase != .idle && phase != .finished }
}

/// State/control only: no native capture, scrolling, permissions or production UI is created here.
@MainActor final class ScrollCaptureSession: ObservableObject {
    @Published private(set) var state = ScrollCaptureState()
    private let driver: any ScrollCaptureDriving
    private let waitForDeadline: @Sendable (UInt64) async throws -> Void
    private let waitBetweenSteps: @Sendable (UInt64) async throws -> Void
    private var current: UUID?
    private var worker: ScrollCaptureWorker?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var finishing: Task<Void, Never>?
    private var completion: ((ScrollCaptureOutcome) -> Void)?
    init(driver: any ScrollCaptureDriving,
         waitForDeadline: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
         waitBetweenSteps: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.driver = driver; self.waitForDeadline = waitForDeadline; self.waitBetweenSteps = waitBetweenSteps
    }
    deinit {
        work?.cancel(); deadline?.cancel(); finishing?.cancel()
        if let worker { Task { await worker.discard() } }
    }
    @discardableResult func start(_ request: ScrollCaptureRequest, completion: @escaping (ScrollCaptureOutcome) -> Void) throws -> Bool {
        guard !state.isBusy else { return false }
        guard Self.valid(request) else { throw ScrollStitchFailure.invalidConfiguration }
        let worker = try ScrollCaptureWorker(configuration: request.stitching)
        let id = UUID()
        current = id; self.worker = worker; self.completion = completion
        state = ScrollCaptureState(runID: id, phase: .capturing)
        deadline = Task { [weak self, waitForDeadline] in
            do { try await waitForDeadline(request.maximumDurationNanoseconds) } catch { return }
            self?.stop(id, reason: .timedOut)
        }
        work = Task { [weak self, driver, waitBetweenSteps] in
            do {
                while self?.mayContinue(id) == true, !Task.isCancelled {
                    self?.setPhase(.capturing, id: id)
                    let sample = try await driver.capture(expected: request.target)
                    guard self?.mayContinue(id) == true, !Task.isCancelled else { return }
                    guard sample.target == request.target,
                          sample.pixels.width == request.target.pixelWidth,
                          sample.pixels.height == request.target.pixelHeight else {
                        self?.stop(id, reason: .targetChanged); return
                    }
                    self?.receivedFrame(id)
                    let (result, progress) = try await worker.append(sample.pixels)
                    guard self?.mayContinue(id) == true, !Task.isCancelled else { return }
                    let duplicates = self?.matched(result, progress: progress, id: id) ?? 0
                    if duplicates >= request.duplicateLimit { self?.stop(id, reason: .noProgress); return }
                    if (self?.state.progress.capturedFrames ?? 0) >= request.maximumFrames {
                        self?.stop(id, reason: .frameLimit); return
                    }
                    guard self?.mayContinue(id) == true, !Task.isCancelled else { return }
                    self?.setPhase(.scrolling, id: id)
                    try await driver.scroll(request.stitching.direction, expected: request.target)
                    guard self?.mayContinue(id) == true, !Task.isCancelled else { return }
                    if request.intervalNanoseconds > 0 { try await waitBetweenSteps(request.intervalNanoseconds) }
                }
            } catch {
                guard self?.mayContinue(id) == true else { return }
                let reason: ScrollCaptureStopReason = (error as? ScrollStitchFailure).map { .stitchFailed($0) } ?? .driverFailed
                self?.stop(id, reason: reason)
            }
        }
        return true
    }
    func cancel() { if let current { stop(current, reason: .cancelled) } }
    func finish() { if let current { stop(current, reason: .userFinished) } }
    private func mayContinue(_ id: UUID) -> Bool { current == id && state.phase != .stopping && state.phase != .finished }
    private func setPhase(_ phase: ScrollCapturePhase, id: UUID) { if mayContinue(id) { state.phase = phase } }
    private func receivedFrame(_ id: UUID) {
        guard mayContinue(id) else { return }
        state.progress.capturedFrames += 1; state.phase = .matching
    }
    private func matched(_ result: ScrollAppendResult, progress: ScrollStitchProgress, id: UUID) -> Int {
        guard mayContinue(id) else { return 0 }
        state.progress.stitching = progress
        switch result {
        case .accepted: state.progress.consecutiveDuplicates = 0
        case .duplicate: state.progress.consecutiveDuplicates += 1
        }
        return state.progress.consecutiveDuplicates
    }
    private func stop(_ id: UUID, reason: ScrollCaptureStopReason) {
        guard mayContinue(id), let worker else { return }
        state.phase = .stopping; work?.cancel(); deadline?.cancel(); work = nil; deadline = nil
        finishing = Task { [weak self] in
            do {
                let (image, progress) = try await worker.finalize()
                self?.complete(id, reason: reason, image: image, progress: progress)
            } catch {
                self?.complete(id, reason: .stitchFailed((error as? ScrollStitchFailure) ?? .invalidFrame), image: nil, progress: nil)
            }
        }
    }
    private func complete(_ id: UUID, reason: ScrollCaptureStopReason, image: ScrollPixelBuffer?, progress: ScrollStitchProgress?) {
        guard current == id, state.phase == .stopping else { return }
        var finalProgress = state.progress
        if let progress { finalProgress.stitching = progress }
        let outcome = ScrollCaptureOutcome(runID: id, reason: reason, progress: finalProgress, image: image)
        let callback = completion
        current = nil; worker = nil; completion = nil; finishing = nil
        state = ScrollCaptureState(runID: id, phase: .finished, progress: finalProgress, outcome: outcome)
        callback?(outcome)
    }
    private static func valid(_ request: ScrollCaptureRequest) -> Bool {
        let t = request.target, c = request.stitching
        guard t.pixelWidth > 0, t.pixelHeight > 0, t.pixelWidth <= 64_000_000 / t.pixelHeight,
              (1...512).contains(request.maximumFrames), request.maximumDurationNanoseconds > 0,
              request.maximumDurationNanoseconds <= 300_000_000_000, request.intervalNanoseconds <= 5_000_000_000,
              (1...16).contains(request.duplicateLimit), c.fixedHeaderRows >= 0, c.fixedFooterRows >= 0,
              c.fixedHeaderRows < t.pixelHeight, c.fixedFooterRows < t.pixelHeight - c.fixedHeaderRows else { return false }
        let pixels = t.pixelWidth * t.pixelHeight
        return c.minimumOverlapRows > 0 && c.minimumOverlapRows < t.pixelHeight - c.fixedHeaderRows - c.fixedFooterRows &&
            c.maximumOutputHeight >= t.pixelHeight && c.maximumOutputHeight <= 64_000_000 &&
            c.maximumOutputPixels >= pixels && c.maximumOutputPixels <= 64_000_000 &&
            c.maximumWorkingBytes >= pixels * 4
    }
}

/// Keeps pixel work off the UI executor. Finalization drops accepted segments even if an old driver never resumes.
private actor ScrollCaptureWorker {
    private var stitcher: ScrollStitcher?
    init(configuration: ScrollStitchConfiguration) throws { stitcher = try ScrollStitcher(configuration: configuration) }
    func append(_ image: ScrollPixelBuffer) throws -> (ScrollAppendResult, ScrollStitchProgress) {
        try Task.checkCancellation()
        guard stitcher != nil else { throw ScrollStitchFailure.invalidConfiguration }
        let result = try stitcher!.append(image)
        return (result, stitcher!.progress)
    }
    func finalize() throws -> (ScrollPixelBuffer?, ScrollStitchProgress) {
        defer { stitcher = nil }
        return (try stitcher?.image(), stitcher?.progress ?? ScrollStitchProgress())
    }
    func discard() { stitcher = nil }
}
