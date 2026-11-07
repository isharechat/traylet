import Foundation
import Testing
@testable import TrayletApp

@Suite("Translation language packs") @MainActor
struct TranslationLanguagePackTests {
    @Test func checksDownloadablePairThenConfirmsInstalledState() async throws {
        let availability = TranslationPackAvailability([.success(.downloadable), .success(.installed)])
        let controller = TranslationLanguagePackController(availability: availability)
        await controller.check().value
        #expect(controller.state == .downloadable)
        #expect(controller.canDownload)

        controller.download()
        let request = try #require(controller.request)
        #expect(controller.state == .preparing && !controller.canDownload)
        let confirmation = try #require(controller.completeDownload(request.id, success: true))
        await confirmation.value

        #expect(controller.request == nil)
        #expect(controller.state == .installed)
        #expect(!controller.canDownload)
        #expect(availability.queries == [
            .init(source: "en", target: "zh-Hans"),
            .init(source: "en", target: "zh-Hans"),
        ])
    }

    @Test func unsupportedAndCheckFailuresStayActionableWithoutInstalling() async {
        let unsupported = TranslationPackAvailability([.success(.unsupported)])
        let controller = TranslationLanguagePackController(availability: unsupported)
        await controller.check().value
        #expect(controller.state == .unsupported)
        #expect(!controller.canDownload)

        let failing = TranslationPackAvailability([.failure(.unavailable)])
        let retryable = TranslationLanguagePackController(availability: failing)
        await retryable.check().value
        #expect(retryable.state == .failed("无法检查系统语言资源，请稍后重试。"))
        #expect(retryable.canDownload)
    }

    @Test func changingLanguagesOrDownloadFailureInvalidatesTheOldRequest() async throws {
        let availability = TranslationPackAvailability([
            .success(.downloadable),
            .success(.downloadable),
        ])
        let controller = TranslationLanguagePackController(availability: availability)
        await controller.check().value
        controller.download()
        let old = try #require(controller.request)
        controller.target = "ja"
        #expect(controller.request == nil && controller.state == .unknown)
        #expect(controller.completeDownload(old.id, success: true) == nil)

        await controller.check().value
        controller.download()
        let current = try #require(controller.request)
        #expect(controller.completeDownload(current.id, success: false) == nil)
        #expect(controller.request == nil)
        #expect(controller.state == .failed("语言包下载未完成。请检查网络或系统设置后重试。"))
    }

    @Test func sameSourceAndTargetNeverStartsADownload() async {
        let controller = TranslationLanguagePackController(availability: TranslationPackAvailability([]))
        controller.target = controller.source
        await controller.check().value
        #expect(controller.state == .failed("请选择不同的原文和目标语言。"))
        #expect(!controller.canDownload)
        controller.download()
        #expect(controller.request == nil)
    }
}

private enum TranslationPackAvailabilityError: Error, Sendable { case unavailable }

private struct TranslationPackQuery: Equatable, Sendable {
    let source: String
    let target: String
}

private final class TranslationPackAvailability: TranslationResourceChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<TranslationResourceState, TranslationPackAvailabilityError>]
    private var recorded: [TranslationPackQuery] = []

    init(_ results: [Result<TranslationResourceState, TranslationPackAvailabilityError>]) {
        self.results = results
    }

    var queries: [TranslationPackQuery] { lock.withLock { recorded } }

    func status(text: String, source: String, target: String) async throws -> TranslationResourceState {
        let result = try lock.withLock {
            recorded.append(.init(source: source, target: target))
            guard !results.isEmpty else { throw TranslationPackAvailabilityError.unavailable }
            return results.removeFirst()
        }
        return try result.get()
    }
}
