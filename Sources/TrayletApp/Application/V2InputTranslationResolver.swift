import AppKit

/// Runs the input-translation shortcut's selection read without activating Traylet first.
///
/// Reading must happen before `present` because presenting activates Traylet and would make the
/// frontmost application Traylet itself, which every strategy rejects. The result is only applied
/// when the input and window state are unchanged since the read began.
@MainActor enum V2InputTranslationResolver {
    @discardableResult
    static func resolve(reader: any V2SelectedTextReading,
                        translation: TranslationController,
                        needsAccessibility: Bool,
                        isTerminated: @escaping () -> Bool = { false }) -> Task<Void, Never> {
        let baselineInput = translation.flow.input
        let baselinePresented = translation.isPresented
        return Task { @MainActor in
            guard !isTerminated() else { return }
            let selection = reader.selectedText()

            // The read is synchronous but may yield (clipboard polling); a user can type or close
            // the window during it. Apply only when both are unchanged.
            let inputUnchanged = translation.flow.input == baselineInput
            let windowStillAvailable = !baselinePresented || translation.isPresented
            guard inputUnchanged, windowStillAvailable else { return }

            if let selection, !selection.isEmpty {
                translation.present(text: selection)
                translation.startSubmission()
            } else {
                translation.present(text: "")
                if needsAccessibility { translation.showAccessibilityNotice() }
            }
        }
    }
}
