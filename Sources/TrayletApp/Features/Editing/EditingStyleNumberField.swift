import AppKit
import SwiftUI

/// A numeric edit captures its target when focus begins and commits once on Return or focus loss.
struct EditingStyleNumberField: NSViewRepresentable {
    @ObservedObject var session: EditingSession
    let key: WritableKeyPath<EditingStyle,CGFloat>
    let range: ClosedRange<CGFloat>
    let label: String
    func makeNSView(context:Context) -> EditingStyleNativeNumberField {
        let field = EditingStyleNativeNumberField(); updateNSView(field,context:context); return field
    }
    func updateNSView(_ field:EditingStyleNativeNumberField,context:Context) {
        let styleContext = session.captureStyleContext()
        field.readValue = { [weak session] in session?.effectiveStyle[keyPath:key] ?? range.lowerBound }
        field.commitValue = { [weak session] value in
            guard let session else { return false }
            var style = session.effectiveStyle; style[keyPath:key] = value
            return session.setEffectiveStyle(style,context:styleContext)
        }
        field.allowedRange = range; field.setAccessibilityLabel(label); field.toolTip = label
        field.refreshValue()
    }
}

@MainActor final class EditingStyleNativeNumberField: NSTextField, NSTextFieldDelegate {
    var readValue: (() -> CGFloat)?
    var commitValue: ((CGFloat) -> Bool)?
    var allowedRange: ClosedRange<CGFloat> = 1...96
    private var editingValue = false
    private var capturedCommit: ((CGFloat) -> Bool)?
    override init(frame:NSRect) {
        super.init(frame:frame)
        isEditable = true; isSelectable = true; isBezeled = true; bezelStyle = .roundedBezel
        font = .systemFont(ofSize:NSFont.systemFontSize(for:.regular)); delegate = self
    }
    convenience init() { self.init(frame:CGRect(x:0,y:0,width:44,height:22)) }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func becomeFirstResponder() -> Bool {
        beginValueEditing(); return super.becomeFirstResponder()
    }
    private func beginValueEditing() {
        guard !editingValue else { return }
        editingValue = true; capturedCommit = commitValue
    }
    func refreshValue() {
        guard !editingValue, let value = readValue?() else { return }
        stringValue = String(format:"%g",Double(value))
    }
    func controlTextDidBeginEditing(_ notification:Notification) { beginValueEditing() }
    func controlTextDidEndEditing(_ notification:Notification) { finishValueEditing(commit:true) }
    private func finishValueEditing(commit:Bool) {
        guard editingValue else { return }
        let callback = capturedCommit
        editingValue = false; capturedCommit = nil
        if commit, let value = Double(stringValue.trimmingCharacters(in:.whitespacesAndNewlines)), value.isFinite,
           allowedRange.contains(CGFloat(value)) { _ = callback?(CGFloat(value)) }
        refreshValue()
    }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishValueEditing(commit:false); window?.endEditing(for:self); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishValueEditing(commit:true); window?.endEditing(for:self); return true
        }
        return false
    }
}
