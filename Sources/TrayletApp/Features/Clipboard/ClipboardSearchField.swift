import AppKit
import SwiftUI

/// A plain native field inside the existing search capsule. The field editor owns text input and IME.
@MainActor struct ClipboardSearchField: NSViewRepresentable {
    let feature: ClipboardFeature
    @ObservedObject private var controller: ClipboardController
    init(feature: ClipboardFeature) { self.feature = feature; controller = feature.controller }
    func makeCoordinator() -> Coordinator { Coordinator(feature: feature) }
    func makeNSView(context: Context) -> ClipboardSearchTextField {
        let field = ClipboardSearchTextField()
        field.isBordered = false; field.isBezeled = false; field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.usesSingleLineMode = true; field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.onAttach = { [weak feature] field in feature?.attachSearchField(field) }
        return field
    }
    func updateNSView(_ field: ClipboardSearchTextField, context: Context) {
        field.placeholderString = V2L("搜索文字或来源应用")
        field.setAccessibilityLabel(V2L("搜索剪贴板历史"))
        if field.stringValue != controller.query, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = controller.query }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        let feature: ClipboardFeature
        init(feature: ClipboardFeature) { self.feature = feature }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Arrow, Return and Escape belong to the input method until composition finishes.
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)): feature.controller.moveVisibleSelection(by: 1)
            case #selector(NSResponder.moveUp(_:)): feature.controller.moveVisibleSelection(by: -1)
            case #selector(NSResponder.insertNewline(_:)): feature.copySelectedAndClose()
            case #selector(NSResponder.cancelOperation(_:)): feature.dismiss()
            default: return false
            }
            return true
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            feature.controller.query = field.stringValue
        }
    }
}
@MainActor final class ClipboardSearchTextField: NSTextField {
    var onAttach: ((NSTextField) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAttach?(self) }
    }
}
