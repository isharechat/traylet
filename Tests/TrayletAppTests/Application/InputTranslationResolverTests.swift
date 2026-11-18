import AppKit
import Testing
@testable import TrayletApp
import TrayletCore

@Suite("Input translation async resolution") @MainActor struct InputTranslationResolverTests {
    @Test func selectionOverwritesPreviousInputAndSubmits() async throws {
        let controller = makeController()
        controller.present(text: "old")
        let reader = ResolverFakeReader(result: "new selection")
        let task = V2InputTranslationResolver.resolve(reader: reader, translation: controller, needsAccessibility: false)
        await task.value
        #expect(controller.flow.input == "new selection")
        #expect(controller.submissionTask != nil)
        controller.close()
    }

    @Test func userInputDuringReadIsNotOverwritten() async throws {
        let controller = makeController()
        controller.present(text: "old")
        let reader = ResolverFakeReader(result: "new selection", onRead: {
            controller.flow.input = "typed by user"
        })
        let task = V2InputTranslationResolver.resolve(reader: reader, translation: controller, needsAccessibility: false)
        await task.value
        #expect(controller.flow.input == "typed by user")
        controller.close()
    }

    @Test func closedWindowIsNotResurrected() async throws {
        let controller = makeController()
        controller.present(text: "old")
        let reader = ResolverFakeReader(result: "new selection", onRead: {
            controller.close()
        })
        let task = V2InputTranslationResolver.resolve(reader: reader, translation: controller, needsAccessibility: false)
        await task.value
        #expect(!controller.isPresented)
        #expect(controller.flow.input == "old")
    }

    private func makeController() -> TranslationController {
        TranslationController(writer: TranslationFakeWriter(),
                              availability: TranslationFakeAvailability(),
                              speech: TranslationFakeSpeech(),
                              presentWindow: { panel in panel.makeKeyAndOrderFront(nil) })
    }
}

@MainActor private final class ResolverFakeReader: V2SelectedTextReading {
    var isAuthorized: Bool { true }
    private let result: String?
    private let onRead: (() -> Void)?
    init(result: String?, onRead: (() -> Void)? = nil) {
        self.result = result
        self.onRead = onRead
    }
    func selectedText() -> String? {
        onRead?()
        return result
    }
}
