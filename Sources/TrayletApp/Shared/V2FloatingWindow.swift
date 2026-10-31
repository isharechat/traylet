import AppKit

/// Traylet windows are transient: once another window or app takes focus they hide.
/// Sheets and modal panels (alerts, open/save panels) started from the window keep it visible.
@MainActor enum V2FloatingWindow {
    static func shouldHide(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isKeyWindow && window.attachedSheet == nil && NSApp.modalWindow == nil && !ownsKeyPopup(of: window)
    }
    /// A popover opened from the window (such as the engine list) becomes key; that must not count as leaving the window.
    static func ownsKeyPopup(of window: NSWindow) -> Bool {
        guard let key = NSApp.keyWindow, key !== window else { return false }
        return key.parent === window || window.childWindows?.contains(key) == true
            || (NSApp.isActive && String(describing: type(of: key)).contains("Popover"))
    }
    static func hideOnResignKey(_ window: NSWindow, hide: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak window] _ in
            // Let focus settle: a sheet or alert opened by the window attaches right after the resign.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if let window, shouldHide(window) { hide() } }
            }
        }
    }
}
