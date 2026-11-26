import AppKit
import ApplicationServices

/// Pasteboard surface used by the clipboard fallbacks, kept behind a protocol so tests can simulate
/// an interleaving write between `clearContents` and `writeObjects`.
@MainActor protocol PasteboardBacking: AnyObject {
    var backingChangeCount: Int { get }
    var backingPasteboardItems: [NSPasteboardItem]? { get }
    func backingString(forType: NSPasteboard.PasteboardType) -> String?
    @discardableResult func backingClearContents() -> Int
    @discardableResult func backingWriteObjects(_ objects: [NSPasteboardItem]) -> Bool
}

extension NSPasteboard: PasteboardBacking {
    var backingChangeCount: Int { changeCount }
    var backingPasteboardItems: [NSPasteboardItem]? { pasteboardItems }
    func backingString(forType type: NSPasteboard.PasteboardType) -> String? { string(forType: type) }
    @discardableResult func backingClearContents() -> Int { clearContents() }
    @discardableResult func backingWriteObjects(_ objects: [NSPasteboardItem]) -> Bool { writeObjects(objects) }
}

/// Tries each reader in order and returns the first non-empty, normalized selection.
@MainActor final class SelectedTextStrategyChain: SelectedTextReading {
    private let strategies: [any SelectedTextReading]
    private let authorized: () -> Bool

    init(strategies: [any SelectedTextReading],
         authorized: @escaping () -> Bool = { AccessibilitySelectedText.isTrusted }) {
        self.strategies = strategies
        self.authorized = authorized
    }

    var isAuthorized: Bool { authorized() }

    func selectedText() -> String? {
        for strategy in strategies {
            guard let text = strategy.selectedText(), let normalized = SelectedTextPolicy.normalize(text) else { continue }
            return normalized
        }
        return nil
    }
}

/// Browser-only JavaScript read. It needs no Accessibility trust; macOS may prompt for Automation
/// permission the first time a script is run against a browser.
@MainActor final class AppleScriptSelectedText: SelectedTextReading {
    var isAuthorized: Bool { true }
    private let frontmostBundleIdentifier: () -> String?
    private let frontmostProcessIdentifier: () -> pid_t?
    private let run: (String) -> String?

    init(frontmostBundleIdentifier: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         frontmostProcessIdentifier: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         run: @escaping (String) -> String? = { AppleScriptSelectedText.runScript($0) }) {
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

    /// Runs the AppleScript on a background queue so the blocking `NSAppleScript` call never
    /// executes on the main actor.
    static func runScript(_ source: String) -> String? {
        var output: String?
        DispatchQueue.global(qos: .userInitiated).sync {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return }
            let result = script.executeAndReturnError(&error)
            guard error == nil else { return }
            output = result.stringValue?.nilIfEmpty
        }
        return output
    }
}

/// Reusable clipboard copy capture with pasteboard backup and a change-count-guarded restore.
@MainActor final class ClipboardCopyCapture {
    private let pasteboard: () -> any PasteboardBacking
    private let setIgnoringNextCopy: (Bool) -> Void
    private let pollInterval: TimeInterval
    private let timeout: TimeInterval

    init(pasteboard: @escaping () -> any PasteboardBacking = { NSPasteboard.general },
         setIgnoringNextCopy: @escaping (Bool) -> Void = { _ in },
         pollInterval: TimeInterval = 0.02,
         timeout: TimeInterval = 0.4) {
        self.pasteboard = pasteboard
        self.setIgnoringNextCopy = setIgnoringNextCopy
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    /// Runs `postCopy`, waits for the board to change, reads a non-empty string, and restores the
    /// previous items only if the board has not changed again since the copy was observed.
    ///
    /// The ignore marker is armed only after a real copy is observed, so empty selections and
    /// failed copy presses never leak it into the user's next real copy.
    func capture(postCopy: () -> Bool, postReadCheck: @escaping () -> Bool = { true }) -> String? {
        let board = pasteboard()
        let backup = ClipboardCopySupport.snapshotItems(board.backingPasteboardItems)
        let before = board.backingChangeCount
        guard postCopy() else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while board.backingChangeCount == before, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }

        let observed = board.backingChangeCount
        guard observed != before else { return nil }
        guard let text = board.backingString(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard postReadCheck() else { return nil }

        // The next board change is our restore, not a user copy, so arm the marker now. The paths
        // above return before this point and therefore leave any pre-existing marker untouched.
        setIgnoringNextCopy(true)
        let restored = ClipboardCopySupport.restore(backup, on: board, observedGeneration: observed)
        if !restored {
            // A concurrent write won; keep that content on the pasteboard and reset the marker so
            // the next user copy is not ignored.
            setIgnoringNextCopy(false)
        }
        return text
    }
}

@MainActor enum ClipboardCopySupport {
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
    /// This is a best-effort guard, not an atomic guarantee: another process can still write between
    /// these checks. A nil/empty backup (file/secret-only content) skips restore rather than clearing.
    @discardableResult static func restore(_ backup: [NSPasteboardItem]?, on board: any PasteboardBacking, observedGeneration: Int) -> Bool {
        guard board.backingChangeCount == observedGeneration else { return false }
        guard let backup, !backup.isEmpty else { return false }
        let clearedGeneration = board.backingClearContents()
        guard board.backingChangeCount == clearedGeneration else { return false }
        let wrote = board.backingWriteObjects(backup)
        guard wrote, board.backingChangeCount == clearedGeneration else { return false }
        return true
    }
}

/// Simulates ⌘C and reads the resulting pasteboard string. Accessibility trust is required to post
/// keyboard events, so it is the last-resort strategy for applications that expose nothing else.
///
/// Secure text fields are not explicitly rejected here; the system refuses to copy their content,
/// so a password field yields no non-empty pasteboard string.
@MainActor final class SimulatedCopySelectedText: SelectedTextReading {
    var isAuthorized: Bool { AccessibilitySelectedText.isTrusted }
    private let capture: ClipboardCopyCapture
    private let postCopy: () -> Void
    private let frontmostProcessIdentifier: () -> pid_t?

    init(capture: ClipboardCopyCapture,
         postCopy: @escaping () -> Void = { SimulatedCopySelectedText.postCommandC() },
         frontmostProcessIdentifier: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
        self.capture = capture
        self.postCopy = postCopy
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
    }

    func selectedText() -> String? {
        guard let pid = frontmostProcessIdentifier(), pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        return capture.capture(postCopy: {
            self.postCopy()
            return true
        }, postReadCheck: {
            self.frontmostProcessIdentifier() == pid
        })
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
///
/// Secure text fields are not explicitly rejected here; macOS disables Copy for them, so the
/// enabled pre-check short-circuits before the pasteboard is touched.
@MainActor final class MenuActionSelectedText: SelectedTextReading {
    struct CopyAction {
        let enabled: Bool
        let press: () -> Bool
    }

    var isAuthorized: Bool { AccessibilitySelectedText.isTrusted }
    private let resolveCopy: () -> CopyAction?
    private let capture: ClipboardCopyCapture
    private let frontmostProcessIdentifier: () -> pid_t?

    init(resolveCopy: @escaping () -> CopyAction? = { MenuActionSelectedText.frontmostCopyAction() },
         capture: ClipboardCopyCapture,
         frontmostProcessIdentifier: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
        self.resolveCopy = resolveCopy
        self.capture = capture
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
    }

    func selectedText() -> String? {
        guard let action = resolveCopy(), action.enabled else { return nil }
        let pid = frontmostProcessIdentifier()
        return capture.capture(postCopy: action.press, postReadCheck: {
            self.frontmostProcessIdentifier() == pid
        })
    }

    static func frontmostCopyAction() -> CopyAction? {
        guard AccessibilitySelectedText.isTrusted,
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
            AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        })
    }

    private static func isEnabled(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success else { return false }
        return (value as? NSNumber)?.boolValue == true
    }

    /// Locates Copy by its command equivalent (C, no extra modifiers). This is an inherent
    /// limitation of reading menus via AX: apps with localized/custom Copy shortcuts may not match,
    /// in which case the chain falls through to the simulated ⌘C shortcut.
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
                  let string = AccessibilitySelectedText.text(from: value) else { return nil }
            return string
        }
        func commandChar(_ element: AXUIElement) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXMenuItemCmdCharAttribute as CFString, &value) == .success,
                  let string = AccessibilitySelectedText.text(from: value) else { return nil }
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
