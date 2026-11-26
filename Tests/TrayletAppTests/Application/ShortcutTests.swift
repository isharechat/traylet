import Foundation
import Testing
@testable import TrayletApp

@MainActor struct ShortcutTests {
    @Test func fixingAStartupRegistrationFailureEnablesActionsWithoutRestarting() throws {
        let store = PreferencesStore(); let driver = FakeShortcutDriver(); driver.reject = true
        let manager = ShortcutManager(preferences: store, driver: driver)
        #expect(throws: (any Error).self) { try manager.start() }
        driver.reject = false
        var invoked = false; manager.onInvoke = { _ in invoked = true }
        manager.begin(.regionCapture); manager.record(.init(keyCode: 0, modifiers: [.control, .option]))
        driver.onInvoke?(.regionCapture)
        #expect(invoked)
    }
    @Test func existingGlobalCombinationIsRecordedAsAConflictWithoutInvokingItsAction() throws {
        let store = PreferencesStore(); let driver = FakeShortcutDriver()
        let manager = ShortcutManager(preferences: store, driver: driver)
        try manager.start()
        var invoked = false; manager.onInvoke = { _ in invoked = true }
        manager.begin(.inputTranslation)
        driver.onInvoke?(.regionCapture)
        #expect(manager.conflict?.occupiedBy == .regionCapture)
        #expect(!invoked && manager.recordingAction == .inputTranslation)
    }
    @Test func conflictingBindingNeedsAChoiceAndReplacingClearsOnlyTheOriginalAction() throws {
        let store = PreferencesStore()
        let driver = FakeShortcutDriver()
        let manager = ShortcutManager(preferences: store, driver: driver)
        try manager.start()
        let original = store.value.shortcuts
        let chord = try #require(original.first { $0.action == .regionCapture }?.chord)
        manager.begin(.inputTranslation)
        manager.record(chord)
        #expect(manager.conflict?.occupiedBy == .regionCapture)
        #expect(store.value.shortcuts == original)
        manager.keepExisting()
        #expect(store.value.shortcuts == original)
        manager.begin(.inputTranslation)
        manager.record(chord)
        manager.replaceExisting()
        #expect(store.value.shortcuts.first { $0.action == .regionCapture }?.chord == nil)
        #expect(store.value.shortcuts.first { $0.action == .inputTranslation }?.chord == chord)
        #expect(driver.active[.inputTranslation] == chord && driver.active[.regionCapture] == nil)
    }

    @Test func registrationOrDiskFailureKeepsOldEffectiveBindingsAndCancelsTheCandidate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-key-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedParent = directory.appendingPathComponent("blocked")
        let store = PreferencesStore(file: blockedParent.appendingPathComponent("preferences.json"))
        let driver = FakeShortcutDriver()
        let manager = ShortcutManager(preferences: store, driver: driver)
        try manager.start()
        let original = store.value.shortcuts
        let active = driver.active
        driver.reject = true
        manager.begin(.inputTranslation)
        manager.record(.init(keyCode: 0, modifiers: [.control, .option]))
        #expect(store.value.shortcuts == original && driver.active == active)
        driver.reject = false
        try Data("Not a directory".utf8).write(to: blockedParent)
        manager.begin(.inputTranslation)
        manager.record(.init(keyCode: 0, modifiers: [.control, .option]))
        #expect(store.value.shortcuts == original && driver.active == active)
        #expect(driver.cancelledCandidates == 1)
        #expect(manager.message != nil)
    }

    @Test func recordingSuppressesGlobalActionsAndCancelOrReservedDefaultsCannotChangePreferences() throws {
        let store = PreferencesStore()
        let driver = FakeShortcutDriver()
        var reserved = false
        let manager = ShortcutManager(preferences: store, driver: driver,
            unavailable: { _ in reserved ? "保留组合" : nil })
        try manager.start()
        var invocations = 0
        manager.onInvoke = { _ in invocations += 1 }
        manager.begin(.regionCapture)
        driver.onInvoke?(.regionCapture)
        #expect(invocations == 0)
        manager.cancel()
        driver.onInvoke?(.regionCapture)
        #expect(invocations == 1)
        let original = store.value.shortcuts
        reserved = true
        manager.restoreDefaults()
        #expect(store.value.shortcuts == original)
        #expect(manager.message == "保留组合")
    }
}

@MainActor private final class FakeShortcutDriver: ShortcutRegistering {
    var onInvoke: ((Action) -> Void)?
    var active: [Action: KeyChord] = [:]
    var reject = false
    var cancelledCandidates = 0
    func prepare(_ bindings: [ShortcutAssignment]) throws -> any ShortcutUpdate {
        if reject { throw CocoaError(.featureUnsupported) }
        return FakeShortcutUpdate(commit: { self.active = Dictionary(uniqueKeysWithValues: bindings.compactMap { item in item.chord.map { (item.action, $0) } }) }, cancel: { self.cancelledCandidates += 1 })
    }
    func stop() { active = [:] }
}

@MainActor private final class FakeShortcutUpdate: ShortcutUpdate {
    let commitAction: () -> Void
    let cancelAction: () -> Void
    init(commit: @escaping () -> Void, cancel: @escaping () -> Void) { commitAction = commit; cancelAction = cancel }
    func commit() { commitAction() }
    func cancel() { cancelAction() }
}
