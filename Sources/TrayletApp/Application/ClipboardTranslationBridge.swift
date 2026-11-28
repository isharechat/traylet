import AppKit

/// Explicit clipboard-to-feature routes (text translation, standalone OCR, and image screenshot translation).
@MainActor final class ClipboardTranslationBridge {
    private let clipboard: ClipboardFeature
    private let translation: TranslationController
    private let ocr: OCRController?
    private let canPresent: () -> Bool
    init(
        clipboard: ClipboardFeature,
        translation: TranslationController,
        ocr: OCRController? = nil,
        canPresent: @escaping () -> Bool = { true }
    ) {
        self.clipboard = clipboard
        self.translation = translation
        self.ocr = ocr
        self.canPresent = canPresent
        clipboard.canRecognizeImage = { [weak self] in self?.canPresent() ?? false }
        clipboard.onRecognizeImage = { [weak self] prepared in
            guard let self, self.canPresent() else { return false }
            self.translation.present(image: prepared.image, decoded: prepared.pixels)
            return true
        }
        clipboard.canTranslateText = { [weak self] in self?.canPresent() ?? false }
        clipboard.onTranslateText = { [weak self] text in
            guard let self, self.canPresent() else { return false }
            self.translation.present(text: text, autoSubmit: true)
            return true
        }
        clipboard.canOpenOCRImage = { [weak self] in self?.ocr != nil && (self?.canPresent() ?? false) }
        clipboard.onOpenOCRImage = { [weak self] prepared in
            guard let self, let ocr = self.ocr, self.canPresent() else { return false }
            ocr.present(image: prepared.image, decoded: prepared.pixels, autoRecognize: true)
            return true
        }
    }
}
