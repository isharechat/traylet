import Foundation
import Testing
@testable import TrayletApp

@MainActor struct PreferencesTests {
    @Test func freshPreferencesHaveNoLegacyInputAndSaveOnlyAfterAnExplicitEdit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-preferences-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("preferences.json")
        let store = V2PreferencesStore(file: file)
        #expect(store.value.appearance == .system)
        #expect(store.value.language == .system)
        #expect(store.value.glassEnabled)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        var edited = store.value
        edited.appearance = .dark
        try store.save(edited)
        #expect(V2PreferencesStore(file: file).value.appearance == .dark)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func malformedOrFuturePreferencesAreNotSilentlyOverwritten() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-bad-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let original = Data("{\"schemaVersion\":999}".utf8)
        try original.write(to: file)
        let store = V2PreferencesStore(file: file)
        #expect(store.failure != nil)
        #expect(throws: (any Error).self) { try store.save(store.value) }
        #expect(try Data(contentsOf: file) == original)
    }
}
