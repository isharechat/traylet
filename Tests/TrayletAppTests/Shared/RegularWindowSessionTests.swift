import AppKit
import Foundation
import Testing
@testable import TrayletApp

@Suite("Regular Window Session") @MainActor struct RegularWindowSessionTests {
    @Test func singleWindowLifecycleTogglesPolicyBetweenAccessoryAndRegular() {
        _ = NSApplication.shared
        var policyChanges: [NSApplication.ActivationPolicy] = []
        let session = RegularWindowSession(
            applyPolicy: { policyChanges.append($0) },
            isAppHidden: { false },
            unhideApp: {},
            schedulePostTransition: { $0() }
        )

        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 200), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var presentCalls = 0

        #expect(session.currentPolicy == .accessory)
        #expect(!session.hasOpenWindows)

        session.present(window, kind: .settings) { w in
            presentCalls += 1
            w.orderBack(nil)
        }
        #expect(session.currentPolicy == .regular)
        #expect(session.hasOpenWindows)
        #expect(policyChanges == [.regular])
        #expect(presentCalls == 2) // initial show + post-transition re-assertion

        window.close()
        #expect(session.currentPolicy == .accessory)
        #expect(!session.hasOpenWindows)
        #expect(policyChanges == [.regular, .accessory])

        // Reopening transitions back to .regular and closing again reverts to .accessory.
        session.present(window, kind: .settings) { w in
            presentCalls += 1
            w.orderBack(nil)
        }
        #expect(session.currentPolicy == .regular)
        #expect(policyChanges == [.regular, .accessory, .regular])

        window.close()
        #expect(session.currentPolicy == .accessory)
        #expect(policyChanges == [.regular, .accessory, .regular, .accessory])
    }

    @Test func multipleWindowsKeepRegularPolicyUntilLastCloses() {
        _ = NSApplication.shared
        var policyChanges: [NSApplication.ActivationPolicy] = []
        let session = RegularWindowSession(
            applyPolicy: { policyChanges.append($0) },
            isAppHidden: { false },
            unhideApp: {},
            schedulePostTransition: { $0() }
        )

        let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settingsWindow.isReleasedWhenClosed = false
        let recoveryWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        recoveryWindow.isReleasedWhenClosed = false

        session.present(settingsWindow, kind: .settings) { _ in }
        session.present(recoveryWindow, kind: .permissionRecovery) { _ in }
        #expect(session.currentPolicy == .regular)
        #expect(policyChanges == [.regular])

        settingsWindow.close()
        #expect(session.currentPolicy == .regular)
        #expect(session.hasOpenWindows)
        #expect(policyChanges == [.regular])

        recoveryWindow.close()
        #expect(session.currentPolicy == .accessory)
        #expect(!session.hasOpenWindows)
        #expect(policyChanges == [.regular, .accessory])
    }

    @Test func handleReopenUnhidesAndRePresentsMostRecentWindow() {
        _ = NSApplication.shared
        var hidden = false
        var unhideCalls = 0
        let session = RegularWindowSession(
            applyPolicy: { _ in },
            isAppHidden: { hidden },
            unhideApp: { unhideCalls += 1; hidden = false },
            schedulePostTransition: { _ in }
        )

        #expect(!session.handleReopen())

        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        second.isReleasedWhenClosed = false

        var presented: [String] = []
        session.present(first, kind: .welcome) { _ in presented.append("welcome") }
        session.present(second, kind: .settings) { _ in presented.append("settings") }
        presented.removeAll()

        hidden = true
        #expect(session.handleReopen())
        #expect(unhideCalls == 1)
        #expect(presented == ["settings"])
        #expect(session.currentPolicy == .regular)

        // Re-focusing welcome makes it the most recent target for handleReopen.
        session.present(first, kind: .welcome) { _ in presented.append("welcome") }
        presented.removeAll()
        #expect(session.handleReopen())
        #expect(presented == ["welcome"])

        first.close()
        second.close()
        #expect(session.currentPolicy == .accessory)
    }

    @Test func appCoordinatorPresentsSettingsWelcomeAndRecoveryAsStandardWindows() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-regular-coordinator-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }

        var policyChanges: [NSApplication.ActivationPolicy] = []
        var presentedWindows: [NSWindow] = []
        let session = RegularWindowSession(
            applyPolicy: { policyChanges.append($0) },
            isAppHidden: { false },
            unhideApp: {},
            schedulePostTransition: { _ in }
        )
        let coordinator = AppCoordinator(
            directory: dir,
            regularWindows: session,
            presentRegularWindow: { presentedWindows.append($0) }
        )

        // 1. Welcome window: standard buttons, normal level, keeps running on close & stops polling timer.
        coordinator.presentWelcomeForTesting()
        let welcome = try #require(coordinator.welcomeWindowForTesting)
        #expect(welcome.styleMask.contains(.titled))
        #expect(welcome.styleMask.contains(.closable))
        #expect(welcome.styleMask.contains(.miniaturizable))
        #expect(welcome.level == .normal)
        #expect(!welcome.hidesOnDeactivate)
        #expect(coordinator.hasAuthorizationTimerForTesting)
        #expect(session.currentPolicy == .regular)

        welcome.close()
        #expect(!coordinator.hasAuthorizationTimerForTesting)
        #expect(session.currentPolicy == .accessory)

        // 2. Permission Recovery window: standard buttons, normal level, toggles policy.
        coordinator.presentPermissionRecoveryForTesting(losses: PermissionLoss(screenRecording: true, accessibility: false))
        let recovery = try #require(coordinator.recoveryWindowForTesting)
        #expect(recovery.styleMask.contains(.titled))
        #expect(recovery.styleMask.contains(.closable))
        #expect(recovery.styleMask.contains(.miniaturizable))
        #expect(recovery.level == .normal)
        #expect(!recovery.hidesOnDeactivate)
        #expect(session.currentPolicy == .regular)

        recovery.close()
        #expect(session.currentPolicy == .accessory)

        // 3. Settings window: toggles policy cleanly and handleReopen restores open Settings.
        coordinator.settings.present()
        let settingsWindow = try #require(presentedWindows.last)
        #expect(settingsWindow.styleMask.contains(.titled))
        #expect(settingsWindow.styleMask.contains(.closable))
        #expect(settingsWindow.styleMask.contains(.miniaturizable))
        #expect(settingsWindow.level == .normal)
        #expect(!settingsWindow.hidesOnDeactivate)
        #expect(session.currentPolicy == .regular)

        let beforeReopen = presentedWindows.count
        #expect(coordinator.handleReopen(hasVisibleWindows: false))
        #expect(presentedWindows.count == beforeReopen + 1)
        #expect(presentedWindows.last === settingsWindow)

        coordinator.settings.close()
        #expect(session.currentPolicy == .accessory)
        #expect(policyChanges == [.regular, .accessory, .regular, .accessory, .regular, .accessory])

        await coordinator.clipboard.shutdownAndWait()
    }
}
