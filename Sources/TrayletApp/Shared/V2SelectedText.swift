import AppKit
import ApplicationServices

@MainActor protocol V2SelectedTextReading {
    func selectedText() -> String?
    /// Selected-text input requires macOS Accessibility trust for this application.
    var isAuthorized: Bool { get }
}

enum V2SelectedTextPolicy {
    static let maximumCharacters = 20_000
    /// Whitespace-only selections are ignored so the existing source text is kept.
    static func normalize(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maximumCharacters))
    }
}

/// The only attributes requested by selected-text input; no fallback reads the entire AXValue.
enum V2SelectedTextAttribute: String { case role = "AXRole", subrole = "AXSubrole", selection = "AXSelectedText" }
enum V2SelectedTextAttributeResult {
    case value(String), unsupported, unavailable
}
/// One external focus snapshot. Its adapter can validate the same focused element before/after a read.
@MainActor struct V2SelectedTextFocus {
    let attribute: @MainActor (V2SelectedTextAttribute) -> V2SelectedTextAttributeResult
    /// Some applications expose only a selected range and its parameterized string.
    let selectedText: @MainActor () -> V2SelectedTextAttributeResult
    let isCurrent: @MainActor () -> Bool

    init(attribute: @escaping @MainActor (V2SelectedTextAttribute) -> V2SelectedTextAttributeResult,
         selectedText: (@MainActor () -> V2SelectedTextAttributeResult)? = nil,
         isCurrent: @escaping @MainActor () -> Bool) {
        let read = attribute
        self.attribute = attribute
        self.selectedText = selectedText ?? { read(.selection) }
        self.isCurrent = isCurrent
    }
}

/// Reads only an explicitly triggered focused selection. Construction does not read AX or request trust.
@MainActor struct V2AccessibilitySelectedText: V2SelectedTextReading {
    private let focus: @MainActor () -> V2SelectedTextFocus?
    init(focus: @escaping @MainActor () -> V2SelectedTextFocus? = Self.nativeFocus) { self.focus = focus }
    static var isTrusted: Bool { AXIsProcessTrusted() }
    var isAuthorized: Bool { Self.isTrusted }
    /// Shows the system's own approval prompt; the user decides in System Settings.
    static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
    /// `AXSelectedText` is normally a string, but some applications expose an attributed string.
    static func text(from value: Any?) -> String? {
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }
    func selectedText() -> String? {
        guard let focus = focus(), focus.isCurrent(), canReadSelection(focus), focus.isCurrent(),
              case .value(let text) = focus.selectedText(),
              focus.isCurrent(), canReadSelection(focus), focus.isCurrent() else { return nil }
        return V2SelectedTextPolicy.normalize(text)
    }
    private func canReadSelection(_ focus: V2SelectedTextFocus) -> Bool {
        guard case .value(let role) = focus.attribute(.role), !role.isEmpty,
              role == role.trimmingCharacters(in: .whitespacesAndNewlines),
              role.caseInsensitiveCompare("AXSecureTextField") != .orderedSame else { return false }
        switch focus.attribute(.subrole) {
        case .value(let subrole):
            return !subrole.isEmpty && subrole == subrole.trimmingCharacters(in: .whitespacesAndNewlines)
                && subrole.caseInsensitiveCompare("AXSecureTextField") != .orderedSame
        case .unsupported:
            // Text areas/static text commonly have no subrole. A text field without classification is ambiguous.
            return role.caseInsensitiveCompare("AXTextField") != .orderedSame
        case .unavailable: return false
        }
    }
    private static func nativeFocus() -> V2SelectedTextFocus? {
        guard isTrusted, let application = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              application != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(application)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        func element(_ owner: AXUIElement, _ name: CFString) -> AXUIElement? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(owner, name, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func focusedElement() -> AXUIElement? {
            // Some system/application combinations do not resolve the system-wide focused-element
            // query. Ask the frontmost application itself first, then keep system-wide as a fallback.
            if let element = element(appElement, kAXFocusedUIElementAttribute as CFString) { return element }
            if let window = element(appElement, kAXFocusedWindowAttribute as CFString),
               let element = element(window, kAXFocusedUIElementAttribute as CFString) { return element }
            return element(system, kAXFocusedUIElementAttribute as CFString)
        }
        guard let element = focusedElement() else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == application else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.5)
        func read(_ attribute: V2SelectedTextAttribute) -> V2SelectedTextAttributeResult {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute.rawValue as CFString, &value)
            if result == .attributeUnsupported { return .unsupported }
            guard result == .success, let string = Self.text(from: value) else { return .unavailable }
            return .value(string)
        }
        func selectedRange() -> CFRange? {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
            guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var range = CFRange()
            guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
            return range
        }
        func readString(for range: CFRange) -> V2SelectedTextAttributeResult {
            var range = range
            guard let parameter = withUnsafePointer(to: &range, { AXValueCreate(.cfRange, $0) }) else { return .unavailable }
            var value: CFTypeRef?
            let result = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value)
            if result == .attributeUnsupported { return .unsupported }
            guard result == .success, let string = Self.text(from: value) else { return .unavailable }
            return .value(string)
        }
        return V2SelectedTextFocus(attribute: read, selectedText: {
            if case .value(let text) = read(.selection), !text.isEmpty { return .value(text) }
            guard let range = selectedRange() else { return .unavailable }
            return readString(for: range)
        }, isCurrent: {
            guard isTrusted, NSWorkspace.shared.frontmostApplication?.processIdentifier == application,
                  let focused = focusedElement() else { return false }
            return CFEqual(focused, element)
        })
    }
}
