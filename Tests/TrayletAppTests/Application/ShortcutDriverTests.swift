import Foundation
import Testing
@testable import TrayletApp

@MainActor struct ShortcutDriverTests {
    @Test func pendingBindingsDoNotInvokeAndCancelPreservesOldRegistration() throws {
        let physical = PhysicalKeys()
        let driver = V2TransactionalShortcutDriver(physical: physical)
        let original = V2ShortcutAssignment.defaults
        try driver.prepare(original).commit()
        let oldIDs = Set(physical.registrations.keys)
        var events: [V2Action] = []; driver.onInvoke = { events.append($0) }
        var next = original
        next[0].chord = .init(keyCode: 0, modifiers: [.control, .option])
        let update = try driver.prepare(next)
        let pendingID = try #require(Set(physical.registrations.keys).subtracting(oldIDs).first)
        physical.onPress?(pendingID)
        #expect(events.isEmpty)
        update.cancel()
        #expect(Set(physical.registrations.keys) == oldIDs)
        let originalID = try #require(physical.registrations.first { $0.value == original[0].chord }?.key)
        physical.onPress?(originalID)
        #expect(events == [.regionCapture])
    }

    @Test func transferringPhysicalChordDoesNotUnregisterItAndFailureReleasesOnlyNewReservations() throws {
        let physical = PhysicalKeys(); let driver = V2TransactionalShortcutDriver(physical: physical)
        let original = V2ShortcutAssignment.defaults
        try driver.prepare(original).commit()
        let old = physical.registrations
        var transferred = original
        transferred[0].chord = nil; transferred[2].chord = original[0].chord
        try driver.prepare(transferred).commit()
        #expect(physical.registrations.values.contains(original[0].chord!))
        #expect(physical.registrationCalls == old.count)
        var actions: [V2Action] = []; driver.onInvoke = { actions.append($0) }
        physical.onPress?(try #require(physical.registrations.first { $0.value == original[0].chord }?.key))
        #expect(actions == [.inputTranslation])
        let active = physical.registrations
        physical.failKeyCode = 1
        var rejected = transferred
        rejected[0].chord = .init(keyCode: 0, modifiers: [.control, .option])
        rejected[1].chord = .init(keyCode: 1, modifiers: [.control, .option])
        #expect(throws: (any Error).self) { try driver.prepare(rejected) }
        #expect(physical.registrations == active)
        driver.stop(); #expect(physical.registrations.isEmpty)
        physical.onPress?(1); #expect(actions == [.inputTranslation])
    }
}

@MainActor private final class PhysicalKeys: V2PhysicalHotKeys {
    var onPress: ((UInt32) -> Void)?
    var registrations: [UInt32: V2KeyChord] = [:]
    var registrationCalls = 0
    var failKeyCode: UInt16?
    func reserve(_ chord: V2KeyChord, id: UInt32) throws {
        if failKeyCode == chord.keyCode { throw CocoaError(.featureUnsupported) }
        registrationCalls += 1; registrations[id] = chord
    }
    func release(_ id: UInt32) { registrations.removeValue(forKey: id) }
    func shutdown() { registrations = [:] }
}
