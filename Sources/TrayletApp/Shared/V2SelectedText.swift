import AppKit
import ApplicationServices

@MainActor protocol V2SelectedTextReading {
    func selectedText() -> String?
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
    let isCurrent: @MainActor () -> Bool
}

/// Reads only an explicitly triggered focused selection. Construction does not read AX or request trust.
@MainActor struct V2AccessibilitySelectedText: V2SelectedTextReading {
    private let focus: @MainActor () -> V2SelectedTextFocus?
    init(focus: @escaping @MainActor () -> V2SelectedTextFocus? = Self.nativeFocus) { self.focus = focus }
    static var isTrusted: Bool { AXIsProcessTrusted() }
    /// Shows the system's own approval prompt; the user decides in System Settings.
    static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    func selectedText() -> String? {
        guard let focus = focus(), focus.isCurrent(), canReadSelection(focus), focus.isCurrent(),
              case .value(let text) = focus.attribute(.selection),
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
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        func focusedElement() -> AXUIElement? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        guard let element = focusedElement() else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == application else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.3)
        return V2SelectedTextFocus(attribute: { attribute in
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute.rawValue as CFString, &value)
            if result == .attributeUnsupported { return .unsupported }
            guard result == .success, let string = value as? String else { return .unavailable }
            return .value(string)
        }, isCurrent: {
            guard isTrusted, NSWorkspace.shared.frontmostApplication?.processIdentifier == application,
                  let focused = focusedElement() else { return false }
            return CFEqual(focused, element)
        })
    }
}
