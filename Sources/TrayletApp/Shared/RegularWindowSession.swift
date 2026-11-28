import AppKit

/// Tracks non-floating standard windows (Settings, initial Welcome authorization, and Permission Recovery)
/// so macOS switches between `.regular` (Dock icon, Cmd+Tab, full menu bar) and `.accessory` (menu bar only).
@MainActor final class RegularWindowSession {
    enum Kind: Hashable {
        case settings
        case welcome
        case permissionRecovery
    }

    private struct Entry {
        weak var window: NSWindow?
        var closeObserver: NSObjectProtocol?
        var onClose: (@MainActor () -> Void)?
        var present: @MainActor (NSWindow) -> Void
    }

    private var openWindows: [Kind: Entry] = [:]
    private var presentationOrder: [Kind] = []
    private var terminating = false
    private(set) var currentPolicy: NSApplication.ActivationPolicy = .accessory

    private let applyPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
    private let isAppHidden: @MainActor () -> Bool
    private let unhideApp: @MainActor () -> Void
    private let schedulePostTransition: @MainActor (@escaping @MainActor () -> Void) -> Void

    init(
        applyPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) },
        isAppHidden: @escaping @MainActor () -> Bool = { NSApp.isHidden },
        unhideApp: @escaping @MainActor () -> Void = { NSApp.unhide(nil) },
        schedulePostTransition: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { block in
            DispatchQueue.main.async { MainActor.assumeIsolated { block() } }
        }
    ) {
        self.applyPolicy = applyPolicy
        self.isAppHidden = isAppHidden
        self.unhideApp = unhideApp
        self.schedulePostTransition = schedulePostTransition
    }

    var hasOpenWindows: Bool {
        openWindows.values.contains { $0.window != nil }
    }

    static func showStandardWindow(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func present(
        _ window: NSWindow,
        kind: Kind,
        onClose: (@MainActor () -> Void)? = nil,
        show: @escaping @MainActor (NSWindow) -> Void
    ) {
        guard !terminating else { return }
        pruneStaleEntries()
        if var existing = openWindows[kind], existing.window === window {
            existing.onClose = onClose
            existing.present = show
            openWindows[kind] = existing
        } else {
            if let stale = openWindows.removeValue(forKey: kind), let observer = stale.closeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            let observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.markClosed(kind) }
            }
            openWindows[kind] = Entry(window: window, closeObserver: observer, onClose: onClose, present: show)
        }
        presentationOrder.removeAll { $0 == kind }
        presentationOrder.append(kind)
        if isAppHidden() { unhideApp() }
        let transitionedToRegular = currentPolicy != .regular
        if transitionedToRegular {
            currentPolicy = .regular
            applyPolicy(.regular)
        }
        show(window)
        if transitionedToRegular {
            // Re-assert activation on the next turn after switching from .accessory so macOS shows the menu bar and window cleanly.
            schedulePostTransition { [weak self, weak window] in
                guard let self, let window, !self.terminating,
                      self.currentPolicy == .regular,
                      self.openWindows[kind]?.window === window,
                      !window.isMiniaturized else { return }
                show(window)
            }
        }
    }

    func markClosed(_ kind: Kind) {
        presentationOrder.removeAll { $0 == kind }
        if let entry = openWindows.removeValue(forKey: kind) {
            if let observer = entry.closeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            entry.onClose?()
        }
        pruneStaleEntries()
        if !terminating && openWindows.isEmpty && currentPolicy != .accessory {
            currentPolicy = .accessory
            applyPolicy(.accessory)
        }
    }

    func handleReopen() -> Bool {
        pruneStaleEntries()
        for kind in presentationOrder.reversed() {
            guard let entry = openWindows[kind], let window = entry.window else { continue }
            if isAppHidden() { unhideApp() }
            entry.present(window)
            return true
        }
        return false
    }

    func prepareForTermination() {
        terminating = true
        for entry in openWindows.values {
            if let observer = entry.closeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        openWindows.removeAll()
        presentationOrder.removeAll()
    }

    private func pruneStaleEntries() {
        let staleKinds = openWindows.compactMap { $0.value.window == nil ? $0.key : nil }
        for kind in staleKinds {
            if let removed = openWindows.removeValue(forKey: kind), let observer = removed.closeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            presentationOrder.removeAll { $0 == kind }
        }
    }
}
