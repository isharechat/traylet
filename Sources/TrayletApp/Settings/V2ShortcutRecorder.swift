import AppKit
import SwiftUI

/// Receives only events delivered to the settings window's recording responder.
@MainActor final class V2ShortcutRecorder {
    let manager: V2ShortcutManager
    init(manager: V2ShortcutManager) { self.manager = manager }
    @discardableResult func handle(_ event: NSEvent) -> Bool {
        guard manager.recordingAction != nil, manager.conflict == nil, event.type == .keyDown else { return false }
        if event.keyCode == 53 { manager.cancel(); return true }
        guard !event.isARepeat else { return true }
        var modifiers: V2KeyModifiers = []
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        manager.record(.init(keyCode: event.keyCode, modifiers: modifiers))
        return true
    }
}

struct V2ShortcutRecordingResponder: NSViewRepresentable {
    @ObservedObject var manager: V2ShortcutManager
    func makeNSView(context: Context) -> RecorderView { RecorderView(manager: manager) }
    func updateNSView(_ view: RecorderView, context: Context) {
        view.setRecording(manager.recordingAction != nil && manager.conflict == nil)
    }
    @MainActor final class RecorderView: NSView {
        let recorder: V2ShortcutRecorder
        private(set) var active = false
        private weak var previousResponder: NSResponder?
        func setRecording(_ value: Bool) {
            let wasActive = active; active = value
            if value {
                if !wasActive {
                    if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor {
                        previousResponder = editor.delegate as? NSResponder
                    } else { previousResponder = window?.firstResponder }
                }
                window?.makeFirstResponder(self)
            } else if wasActive, window?.firstResponder === self {
                window?.makeFirstResponder(previousResponder); previousResponder = nil
            }
        }
        init(manager: V2ShortcutManager) { recorder = V2ShortcutRecorder(manager: manager); super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override var acceptsFirstResponder: Bool { active }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if active { window?.makeFirstResponder(self) } }
        override func keyDown(with event: NSEvent) { if !recorder.handle(event) { super.keyDown(with: event) } }
        override func performKeyEquivalent(with event: NSEvent) -> Bool { recorder.handle(event) || super.performKeyEquivalent(with: event) }
    }
}
