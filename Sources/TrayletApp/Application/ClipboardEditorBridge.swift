import AppKit

/// Owns only the return route. Image bytes remain in history; no copy or capture occurs here.
@MainActor final class ClipboardEditorBridge {
    private let clipboard: ClipboardFeature
    private let editor: CaptureEditorController
    private let availableFrame: () -> CGRect?
    private let canPresent: () -> Bool
    private let shouldReturn: () -> Bool
    private var fromClipboard = false
    init(clipboard: ClipboardFeature, editor: CaptureEditorController,
         availableFrame: @escaping () -> CGRect? = { (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame },
         canPresent: @escaping () -> Bool = { true }, shouldReturn: @escaping () -> Bool = { NSApp.isActive }) {
        self.clipboard = clipboard; self.editor = editor; self.availableFrame = availableFrame
        self.canPresent = canPresent; self.shouldReturn = shouldReturn
        clipboard.canEditImage = { [weak self] in self.map { !$0.editor.isOpen && $0.canPresent() } ?? false }
        clipboard.onEditImage = { [weak self] prepared in
            guard let self, !self.editor.isOpen, self.canPresent(), let frame = self.availableFrame(),
                  self.editor.presentImported(image: prepared.image, decoded: prepared.pixels, availableFrame: frame) else { return false }
            self.fromClipboard = true; return true
        }
    }
    /// Returns true when this completion belonged to history, even if another app now has focus.
    @discardableResult func complete() -> Bool {
        guard fromClipboard else { return false }
        fromClipboard = false
        if shouldReturn() { clipboard.present() }
        return true
    }
    func abandon() { fromClipboard = false; clipboard.imageEditing.cancel() }
}
