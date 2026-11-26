import AppKit
import ApplicationServices

@MainActor protocol SelectedTextReading {
    func selectedText() -> String?
    /// Selected-text input requires macOS Accessibility trust for this application.
    var isAuthorized: Bool { get }
}

enum SelectedTextPolicy {
    static let maximumCharacters = 20_000
    /// Whitespace-only selections are ignored so the existing source text is kept.
    static func normalize(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maximumCharacters))
    }
}

/// The only attributes requested by selected-text input; no fallback reads the entire AXValue.
enum SelectedTextAttribute: String { case role = "AXRole", subrole = "AXSubrole", selection = "AXSelectedText" }
enum SelectedTextAttributeResult {
    case value(String), unsupported, unavailable
}
/// One external focus snapshot. Its adapter can validate the same focused element before/after a read.
@MainActor struct SelectedTextFocus {
    let attribute: @MainActor (SelectedTextAttribute) -> SelectedTextAttributeResult
    /// Some applications expose only a selected range and its parameterized string.
    let selectedText: @MainActor () -> SelectedTextAttributeResult
    let isCurrent: @MainActor () -> Bool

    init(attribute: @escaping @MainActor (SelectedTextAttribute) -> SelectedTextAttributeResult,
         selectedText: (@MainActor () -> SelectedTextAttributeResult)? = nil,
         isCurrent: @escaping @MainActor () -> Bool) {
        let read = attribute
        self.attribute = attribute
        self.selectedText = selectedText ?? { read(.selection) }
        self.isCurrent = isCurrent
    }
}

/// Reads only an explicitly triggered focused selection. Construction does not read AX or request trust.
@MainActor struct AccessibilitySelectedText: SelectedTextReading {
    private let focus: @MainActor () -> SelectedTextFocus?
    init(focus: @escaping @MainActor () -> SelectedTextFocus? = Self.nativeFocus) { self.focus = focus }
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
    /// Ordered fallback for the selected text of one focus snapshot: AXSelectedText, then a plain
    /// selected range, then a TextMarker range (Chrome/Edge often expose only the marker range).
    static func selectedTextFallback(selection: () -> SelectedTextAttributeResult,
                                     selectedRange: () -> CFRange?,
                                     stringForRange: (CFRange) -> SelectedTextAttributeResult,
                                     selectedTextMarkerRange: () -> CFTypeRef?,
                                     stringForTextMarkerRange: (CFTypeRef) -> SelectedTextAttributeResult) -> SelectedTextAttributeResult {
        if case .value(let text) = selection(), !text.isEmpty { return .value(text) }
        if let range = selectedRange() { return stringForRange(range) }
        if let markerRange = selectedTextMarkerRange() { return stringForTextMarkerRange(markerRange) }
        return .unavailable
    }
    func selectedText() -> String? {
        guard let focus = focus(), focus.isCurrent(), canReadSelection(focus), focus.isCurrent(),
              case .value(let text) = focus.selectedText(),
              focus.isCurrent(), canReadSelection(focus), focus.isCurrent() else { return nil }
        return SelectedTextPolicy.normalize(text)
    }
    private func canReadSelection(_ focus: SelectedTextFocus) -> Bool {
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
    private static func nativeFocus() -> SelectedTextFocus? {
        guard isTrusted, let application = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              application != ProcessInfo.processInfo.processIdentifier else { return nil }
        let deadline = ContinuousClock.now + .milliseconds(350)
        func timedOut() -> Bool { ContinuousClock.now >= deadline }
        let appElement = AXUIElementCreateApplication(application)
        AXUIElementSetMessagingTimeout(appElement, 0.15)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        func element(_ owner: AXUIElement, _ name: CFString) -> AXUIElement? {
            guard !timedOut() else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(owner, name, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func focusedElement(in window: AXUIElement) -> AXUIElement? {
            // Chrome and a few other applications answer none of the focused-element queries,
            // but still mark the focused element with AXFocused inside the focused window.
            // Walk only that window's subtree (bounded) and keep the deepest focused element.
            let maximumElements = 512
            let maximumDepth = 24
            var visited = 0
            var deepest: AXUIElement?
            var deepestDepth = -1
            func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
                guard !timedOut() else { return nil }
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
                return value
            }
            func isFocused(_ element: AXUIElement) -> Bool {
                AXUIElementSetMessagingTimeout(element, 0.15)
                guard let value = attribute(element, kAXFocusedAttribute as CFString) else { return false }
                return (value as? NSNumber)?.boolValue == true
            }
            func children(of element: AXUIElement) -> [AXUIElement] {
                AXUIElementSetMessagingTimeout(element, 0.15)
                guard let value = attribute(element, kAXChildrenAttribute as CFString),
                      CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
                return (value as? [AXUIElement]) ?? []
            }
            func search(_ element: AXUIElement, depth: Int) {
                guard !timedOut(), visited < maximumElements, depth <= maximumDepth else { return }
                visited += 1
                if isFocused(element), depth > deepestDepth {
                    deepest = element
                    deepestDepth = depth
                }
                for child in children(of: element) { search(child, depth: depth + 1) }
            }
            for child in children(of: window) { search(child, depth: 1) }
            return deepest
        }
        enum FocusPath { case app, window, system, windowTree }
        func resolveFocused(preferring preferred: FocusPath?) -> (AXUIElement, FocusPath)? {
            let order: [FocusPath] = switch preferred {
            case .app, nil: [.app, .window, .system, .windowTree]
            case .window: [.window, .app, .system, .windowTree]
            case .system: [.system, .app, .window, .windowTree]
            case .windowTree: [.windowTree, .app, .window, .system]
            }
            var cachedWindow: AXUIElement?
            var fetchedWindow = false
            func focusedWindow() -> AXUIElement? {
                if !fetchedWindow {
                    cachedWindow = element(appElement, kAXFocusedWindowAttribute as CFString)
                    fetchedWindow = true
                }
                return cachedWindow
            }
            for path in order {
                guard !timedOut() else { return nil }
                switch path {
                case .app:
                    if let el = element(appElement, kAXFocusedUIElementAttribute as CFString) { return (el, .app) }
                case .window:
                    if let win = focusedWindow(), let el = element(win, kAXFocusedUIElementAttribute as CFString) { return (el, .window) }
                case .system:
                    if let el = element(system, kAXFocusedUIElementAttribute as CFString) { return (el, .system) }
                case .windowTree:
                    if let win = focusedWindow() {
                        AXUIElementSetMessagingTimeout(win, 0.15)
                        if let el = focusedElement(in: win) { return (el, .windowTree) }
                    }
                }
            }
            return nil
        }
        guard let (element, resolvedPath) = resolveFocused(preferring: nil) else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == application else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.15)
        func read(_ attribute: SelectedTextAttribute) -> SelectedTextAttributeResult {
            guard !timedOut() else { return .unavailable }
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute.rawValue as CFString, &value)
            if result == .attributeUnsupported { return .unsupported }
            guard result == .success, let string = Self.text(from: value) else { return .unavailable }
            return .value(string)
        }
        func selectedRange() -> CFRange? {
            guard !timedOut() else { return nil }
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
            guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var range = CFRange()
            guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
            return range
        }
        func readString(for range: CFRange) -> SelectedTextAttributeResult {
            guard !timedOut() else { return .unavailable }
            var range = range
            guard let parameter = withUnsafePointer(to: &range, { AXValueCreate(.cfRange, $0) }) else { return .unavailable }
            var value: CFTypeRef?
            let result = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value)
            if result == .attributeUnsupported { return .unsupported }
            guard result == .success, let string = Self.text(from: value) else { return .unavailable }
            return .value(string)
        }
        func selectedTextMarkerRange() -> CFTypeRef? {
            guard !timedOut() else { return nil }
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextMarkerRangeAttribute as CFString, &value)
            guard result == .success, let value, CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
            return value
        }
        func readString(forTextMarkerRange markerRange: CFTypeRef) -> SelectedTextAttributeResult {
            guard !timedOut() else { return .unavailable }
            var value: CFTypeRef?
            let result = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForTextMarkerRangeParameterizedAttribute as CFString, markerRange, &value)
            if result == .attributeUnsupported { return .unsupported }
            guard result == .success, let string = Self.text(from: value) else { return .unavailable }
            return .value(string)
        }
        return SelectedTextFocus(attribute: read, selectedText: {
            Self.selectedTextFallback(
                selection: { read(.selection) },
                selectedRange: selectedRange,
                stringForRange: readString,
                selectedTextMarkerRange: selectedTextMarkerRange,
                stringForTextMarkerRange: readString(forTextMarkerRange:)
            )
        }, isCurrent: {
            guard !timedOut(), isTrusted, NSWorkspace.shared.frontmostApplication?.processIdentifier == application,
                  let (focused, _) = resolveFocused(preferring: resolvedPath) else { return false }
            return CFEqual(focused, element)
        })
    }
}
