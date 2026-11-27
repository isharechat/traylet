import AppKit
import Foundation
import Testing
import TrayletCore
@testable import TrayletApp

@Suite("OCR Controller") @MainActor struct OCRControllerTests {
    @Test func recognizesWithVisionAppliesPostProcessingAndAutoCopy() async throws {
        let config = OCRConfiguration()
        config.mergeLineBreaks = true
        config.autoCopy = true
        let writer = FakeOCRWriter()
        let vision = FakeVisionRecognizer(result: "第一行\n第二行")
        let controller = OCRController(
            configuration: config,
            visionRecognizer: vision,
            aiRecognizer: FakeAIRecognizer(result: "AI"),
            writer: writer,
            speech: FakeOCRSpeech(),
            presentWindow: { _ in }
        )

        let image = try makeSampleRasterImage()
        controller.present(image: image, autoRecognize: true)
        await controller.recognitionTaskHandle?.value

        #expect(controller.phase == .ready)
        #expect(controller.text == "第一行第二行")
        #expect(writer.copied == ["第一行第二行"])
    }

    @Test func switchesBetweenVisionAndAIAndSendsToTranslation() async throws {
        let config = OCRConfiguration()
        let controller = OCRController(
            configuration: config,
            visionRecognizer: FakeVisionRecognizer(result: "Vision Text"),
            aiRecognizer: FakeAIRecognizer(result: "AI Markdown"),
            writer: FakeOCRWriter(),
            speech: FakeOCRSpeech(),
            presentWindow: { _ in }
        )

        var translatedPayload: (String, RasterImage?)?
        controller.onTranslate = { text, image in translatedPayload = (text, image) }

        let image = try makeSampleRasterImage()
        controller.present(image: image, autoRecognize: true)
        await controller.recognitionTaskHandle?.value
        #expect(controller.text == "Vision Text")

        controller.selectEngine(.ai)
        await controller.recognitionTaskHandle?.value
        #expect(controller.text == "AI Markdown")

        controller.sendToTranslation()
        #expect(translatedPayload?.0 == "AI Markdown")
        #expect(translatedPayload?.1 == image)
    }

    @Test func translationPreservesSourceImageAndJumpsBackToOCR() async throws {
        let translation = TranslationController(presentWindow: { _ in })
        var openedImage: RasterImage?
        translation.onOpenOCR = { image in openedImage = image }

        let image = try makeSampleRasterImage()
        translation.present(text: "Hello", sourceImage: image, autoSubmit: false)
        #expect(translation.lastSourceImage == image)
        translation.openOCR()
        #expect(openedImage == image)
    }

    private func makeSampleRasterImage() throws -> RasterImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let png = try #require(rep.representation(using: .png, properties: [:]))
        return try RasterImage(pngData: png)
    }
}

private struct FakeVisionRecognizer: TranslationRecognizing {
    let result: String
    func recognize(_ image: RasterImage) async throws -> String { result }
}

private struct FakeAIRecognizer: OCRAIRecognizing {
    let result: String
    func recognize(_ request: OCRAIRequest) async throws -> String { result }
}

@MainActor private final class FakeOCRWriter: TextOutputWriting {
    var copied: [String] = []
    func copyText(_ text: String) -> CopyOutcome {
        copied.append(text)
        return .copied
    }
}

@MainActor private final class FakeOCRSpeech: TranslationSpeaking {
    var onFinish: (@MainActor @Sendable () -> Void)?
    func speak(_ text: String, language: String) throws {}
    func stop() {}
}
