import AppKit
import ApplicationServices

/// Tries each reader in order and returns the first non-empty, normalized selection.
@MainActor final class V2SelectedTextStrategyChain: V2SelectedTextReading {
    private let strategies: [any V2SelectedTextReading]
    private let authorized: () -> Bool

    init(strategies: [any V2SelectedTextReading],
         authorized: @escaping () -> Bool = { V2AccessibilitySelectedText.isTrusted }) {
        self.strategies = strategies
        self.authorized = authorized
    }

    var isAuthorized: Bool { authorized() }

    func selectedText() -> String? {
        for strategy in strategies {
            guard let text = strategy.selectedText(), let normalized = V2SelectedTextPolicy.normalize(text) else { continue }
            return normalized
        }
        return nil
    }
}

/// Browser-only JavaScript read. It needs no Accessibility trust; macOS may prompt for Automation
/// permission the first time a script is run against a browser.
@MainActor final class V2AppleScriptSelectedText: V2SelectedTextReading {
    var isAuthorized: Bool { true }
    private let frontmostBundleIdentifier: () -> String?
    private let frontmostProcessIdentifier: () -> pid_t?
    private let run: (String) -> String?

    init(frontmostBundleIdentifier: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         frontmostProcessIdentifier: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         run: @escaping (String) -> String? = { V2AppleScriptSelectedText.runScript($0) }) {
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.run = run
    }

    func selectedText() -> String? {
        guard let bundleID = frontmostBundleIdentifier(), let source = Self.script(bundleIdentifier: bundleID) else { return nil }
        let targetPID = frontmostProcessIdentifier()
        let text = run(source)
        // Keep the same focus contract as the AX path: a result from a since-changed frontmost app is discarded.
        guard frontmostBundleIdentifier() == bundleID, frontmostProcessIdentifier() == targetPID else { return nil }
        return text
    }

    static func script(bundleIdentifier: String) -> String? {
        switch bundleIdentifier {
        case "com.apple.Safari":
            return #"tell application "Safari" to do JavaScript "window.getSelection().toString()" in document 1"#
        case "com.google.Chrome":
            return #"tell application "Google Chrome" to execute front window's active tab javascript "window.getSelection().toString()""#
        case "com.microsoft.edgemac", "com.microsoft.Edge":
            return #"tell application "Microsoft Edge" to execute front window's active tab javascript "window.getSelection().toString()""#
        default:
            return nil
        }
    }

    static func runScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.stringValue?.nilIfEmpty
    }
}

/// Reusable clipboard copy capture with pasteboard backup and a change-count-guarded restore.
@MainActor final class V2ClipboardCopyCapture {
    private let pasteboard: () -> NSPasteboard
    private let markIgnoreNextCopy: () -> Void
    private let pollInterval: TimeInterval
    private let timeout: TimeInterval

    init(pasteboard: @escaping () -> NSPasteboard = { .general },
         markIgnoreNextCopy: @escaping () -> Void = {},
         pollInterval: TimeInterval = 0.02,
         timeout: TimeInterval = 0.4) {
        self.pasteboard = pasteboard
        self.markIgnoreNextCopy = markIgnoreNextCopy
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    /// Runs `postCopy`, waits for the board to change, reads a non-empty string, and restores the
    /// previous items only if the board has not changed again since the copy was observed.
    func capture(postCopy: () -> Void) -> String? {
        let board = pasteboard()
        let backup = V2ClipboardCopySupport.snapshotItems(board.pasteboardItems)
        let before = board.changeCount
        markIgnoreNextCopy()
        postCopy()

        let deadline = Date().addingTimeInterval(timeout)
        while board.changeCount == before, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }

        let observed = board.changeCount
        guard observed != before,
              let text = board.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        if board.changeCount == observed {
            // Re-arm the ignore marker so a restore that lands in a later poll is not recorded.
            markIgnoreNextCopy()
            _ = V2ClipboardCopySupport.restore(backup, on: board, observedGeneration: observed)
        }
        return text
    }
}

@MainActor enum V2ClipboardCopySupport {
    /// Copies only the safe representations of each pasteboard item into fresh items, so the
    /// original items can be restored after `clearContents` without reading file or secret bodies.
    static func snapshotItems(_ items: [NSPasteboardItem]?) -> [NSPasteboardItem]? {
        guard let items, !items.isEmpty else { return nil }
        var copies: [NSPasteboardItem] = []
        for item in items {
            let copy = NSPasteboardItem()
            for type in item.types where isSafe(type) {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            if !copy.types.isEmpty { copies.append(copy) }
        }
        return copies.isEmpty ? nil : copies
    }
    private static func isSafe(_ type: NSPasteboard.PasteboardType) -> Bool {
        let value = type.rawValue.lowercased()
        return !(value.contains("file") || value.contains("concealed") || value.contains("transient")
            || value.contains("autogenerated") || value.contains("password"))
    }
    /// Restores the backup only when the board is still at the generation that produced the copy.
    /// Returns false (and leaves the board untouched) when a concurrent write changed it first.
    @discardableResult static func restore(_ backup: [NSPasteboardItem]?, on board: NSPasteboard, observedGeneration: Int) -> Bool {
        guard board.changeCount == observedGeneration else { return false }
        board.clearContents()
        if let backup, !backup.isEmpty { _ = board.writeObjects(backup) }
        return true
    }
}

/// Simulates ⌘C and reads the resulting pasteboard string. Accessibility trust is required to post
/// keyboard events, so it is the last-resort strategy for applications that expose nothing else.
@MainActor final class V2SimulatedCopySelectedText: V2SelectedTextReading {
    var isAuthorized: Bool { V2AccessibilitySelectedText.isTrusted }
    private let capture: V2ClipboardCopyCapture
    private let postCopy: () -> Void
    private let frontmostProcessIdentifier: () -> pid_t?

    init(capture: V2ClipboardCopyCapture,
         postCopy: @escaping () -> Void = { V2SimulatedCopySelectedText.postCommandC() },
         frontmostProcessIdentifier: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
        self.capture = capture
        self.postCopy = postCopy
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
    }

    func selectedText() -> String? {
        guard let pid = frontmostProcessIdentifier(), pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        _ = pid
        return capture.capture(postCopy: postCopy)
    }

    static func postCommandC() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// AX menu-bar Copy with an enabled pre-check so a disabled Copy (no selection) never touches the
/// pasteboard. When enabled, the menu item is pressed and the copy capture reads and restores.
@MainActor final class V2MenuActionSelectedText: V2SelectedTextReading {
    struct CopyAction {
        let enabled: Bool
        let press: () -> Void
    }

    var isAuthorized: Bool { V2AccessibilitySelectedText.isTrusted }
    private let resolveCopy: () -> CopyAction?
    private let capture: V2ClipboardCopyCapture

    init(resolveCopy: @escaping () -> CopyAction? = { V2MenuActionSelectedText.frontmostCopyAction() },
         capture: V2ClipboardCopyCapture) {
        self.resolveCopy = resolveCopy
        self.capture = capture
    }

    func selectedText() -> String? {
        guard let action = resolveCopy(), action.enabled else { return nil }
        return capture.capture(postCopy: action.press)
    }

    static func frontmostCopyAction() -> CopyAction? {
        guard V2AccessibilitySelectedText.isTrusted,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let menuBar = value as! AXUIElement
        guard let item = findCopyItem(in: menuBar) else { return nil }
        return CopyAction(enabled: isEnabled(item), press: {
            _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
        })
    }

    private static func isEnabled(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success else { return false }
        return (value as? NSNumber)?.boolValue == true
    }

    private static func findCopyItem(in element: AXUIElement) -> AXUIElement? {
        var visited = 0
        func children(of element: AXUIElement) -> [AXUIElement] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
            return (value as? [AXUIElement]) ?? []
        }
        func role(_ element: AXUIElement) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
                  let string = V2AccessibilitySelectedText.text(from: value) else { return nil }
            return string
        }
        func commandChar(_ element: AXUIElement) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXMenuItemCmdCharAttribute as CFString, &value) == .success,
                  let string = V2AccessibilitySelectedText.text(from: value) else { return nil }
            return string
        }
        func commandModifiers(_ element: AXUIElement) -> Int {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXMenuItemCmdModifiersAttribute as CFString, &value) == .success else { return -1 }
            return (value as? NSNumber)?.intValue ?? -1
        }
        func search(_ element: AXUIElement) -> AXUIElement? {
            visited += 1
            guard visited <= 512 else { return nil }
            if role(element) == "AXMenuItem", commandChar(element) == "C", commandModifiers(element) == 0 {
                return element
            }
            for child in children(of: element) {
                if let found = search(child) { return found }
            }
            return nil
        }
        return search(element)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
