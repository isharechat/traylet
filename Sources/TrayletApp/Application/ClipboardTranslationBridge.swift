import AppKit

/// Explicit local OCR route; translation still requires the window's submit/send actions.
@MainActor final class ClipboardTranslationBridge {
    private let clipboard: ClipboardFeature
    private let translation: TranslationController
    private let canPresent: () -> Bool
    init(clipboard: ClipboardFeature, translation: TranslationController, canPresent: @escaping () -> Bool = { true }) {
        self.clipboard = clipboard; self.translation = translation; self.canPresent = canPresent
        clipboard.canRecognizeImage = { [weak self] in self?.canPresent() ?? false }
        clipboard.onRecognizeImage = { [weak self] prepared in
            guard let self, self.canPresent() else { return false }
            self.translation.present(image: prepared.image, decoded: prepared.pixels)
            return true
        }
    }
}
