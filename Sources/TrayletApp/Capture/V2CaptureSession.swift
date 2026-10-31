import AppKit
import Combine
import ScreenCaptureKit
import UniformTypeIdentifiers
import TrayletCore

struct V2CaptureTarget: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let logicalSize: CGSize
    let pixelWidth: Int
    let pixelHeight: Int
    var isValid: Bool {
        logicalSize.width.isFinite && logicalSize.height.isFinite && logicalSize.width >= 60 && logicalSize.height >= 60 &&
        pixelWidth > 0 && pixelHeight > 0 && pixelWidth <= 64_000_000 && pixelHeight <= 64_000_000 &&
        Int64(pixelWidth) * Int64(pixelHeight) <= 64_000_000
    }
    @MainActor init?(screen: NSScreen) {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        displayID = id; logicalSize = screen.frame.size
        pixelWidth = Int((screen.frame.width * screen.backingScaleFactor).rounded())
        pixelHeight = Int((screen.frame.height * screen.backingScaleFactor).rounded())
    }
    init(displayID: CGDirectDisplayID, logicalSize: CGSize, pixelWidth: Int, pixelHeight: Int) {
        self.displayID = displayID; self.logicalSize = logicalSize; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }
}

/// The PNG crossing module interfaces, plus the already decoded pixels so the editor need not decode it again.
struct V2Capture: @unchecked Sendable {
    let image: RasterImage
    var pixels: CGImage?
}

@MainActor protocol V2ScreenCapturing: AnyObject {
    func capture(_ target: V2CaptureTarget) async throws -> V2Capture
}

/// One request token owns its deadline and callback. Cancellation never waits on an unresponsive capture API.
@MainActor final class V2CaptureSession: ObservableObject {
    @Published private(set) var isBusy = false
    private let source: any V2ScreenCapturing
    private let timeoutNanoseconds: UInt64
    private let waitForDeadline: (UInt64) async throws -> Void
    private var current: UUID?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var completion: ((Result<V2Capture, any Error>) -> Void)?
    init(source: any V2ScreenCapturing = V2NativeScreenCapture(), timeoutNanoseconds: UInt64 = 8_000_000_000,
         waitForDeadline: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.source = source; self.timeoutNanoseconds = timeoutNanoseconds; self.waitForDeadline = waitForDeadline
    }
    @discardableResult func start(_ target: V2CaptureTarget, completion: @escaping (Result<V2Capture, any Error>) -> Void) -> Bool {
        guard current == nil else { return false }
        let token = UUID(); current = token; isBusy = true; self.completion = completion
        work = Task { [weak self, source] in
            do { let image = try await source.capture(target); self?.finish(token, .success(image)) }
            catch { self?.finish(token, .failure(error)) }
        }
        deadline = Task { [weak self, timeoutNanoseconds, waitForDeadline] in
            do { try await waitForDeadline(timeoutNanoseconds) } catch { return }
            self?.finish(token, .failure(FeatureIssue.unavailable("截图超时，请重试。")))
        }
        return true
    }
    func cancel() { if let current { finish(current, .failure(FeatureIssue.cancelled)) } }
    private func finish(_ token: UUID, _ result: Result<V2Capture, any Error>) {
        guard current == token else { return }
        current = nil; isBusy = false; work?.cancel(); deadline?.cancel(); work = nil; deadline = nil
        let callback = completion; completion = nil; callback?(result)
    }
}

@MainActor final class V2NativeScreenCapture: V2ScreenCapturing {
    func capture(_ target: V2CaptureTarget) async throws -> V2Capture {
        guard target.isValid else { throw FeatureIssue.invalidInput("屏幕尺寸超出截图限制。") }
        guard CGPreflightScreenCaptureAccess() else { throw FeatureIssue.permission("请先在系统设置允许 Traylet 录制屏幕，再重试。") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
            throw FeatureIssue.unavailable("目标屏幕已断开，请重试。")
        }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = target.pixelWidth; configuration.height = target.pixelHeight
        configuration.showsCursor = false
        let pixels = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        guard NSScreen.screens.compactMap(V2CaptureTarget.init(screen:)).contains(target) else {
            throw FeatureIssue.unavailable("截图期间屏幕或缩放已变化，请重新截图。")
        }
        // Encoding a full-screen PNG takes hundreds of milliseconds; keep it off the main thread.
        let image = try await Self.encode(pixels)
        try Task.checkCancellation()
        return V2Capture(image: image, pixels: pixels)
    }
    nonisolated private static func encode(_ pixels: CGImage) async throws -> RasterImage {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw FeatureIssue.unavailable("截图无法编码，请重试。")
        }
        CGImageDestinationAddImage(destination, pixels, nil)
        guard CGImageDestinationFinalize(destination) else { throw FeatureIssue.unavailable("截图无法编码，请重试。") }
        return try RasterImage(pngData: data as Data)
    }
}
