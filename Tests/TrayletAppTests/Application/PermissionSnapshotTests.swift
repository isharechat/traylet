import Foundation
import Testing
@testable import TrayletApp

@MainActor private final class LossBox {
    var value: PermissionLoss?
}

@MainActor private final class LossListBox {
    var values: [PermissionLoss] = []
}

@MainActor private final class BoolBox {
    var value: Bool
    init(_ value: Bool = false) { self.value = value }
}

@MainActor struct PermissionSnapshotTests {
    @Test func snapshotRoundTripsWithPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-permission-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("permissions.json")
        let store = PermissionSnapshotStore(file: file)
        #expect(store.load() == nil)
        var snapshot = PermissionSnapshot()
        snapshot.lastScreenRecordingGranted = true
        snapshot.lastAccessibilityGranted = false
        try store.save(snapshot)
        #expect(store.load() == snapshot)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func corruptOversizedOrSymbolicSnapshotsLoadAsNilWithoutDeleting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-permission-bad-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("permissions.json")

        let corrupt = Data("not json".utf8)
        try corrupt.write(to: file)
        #expect(PermissionSnapshotStore(file: file).load() == nil)
        #expect(try Data(contentsOf: file) == corrupt)

        let oversized = Data(repeating: 0x61, count: PermissionSnapshotStore.maximumBytes + 1)
        try oversized.write(to: file)
        #expect(PermissionSnapshotStore(file: file).load() == nil)
        #expect(try Data(contentsOf: file) == oversized)

        let futureSchema = Data(#"{"schemaVersion":999,"lastScreenRecordingGranted":true,"lastAccessibilityGranted":true}"#.utf8)
        try futureSchema.write(to: file)
        #expect(PermissionSnapshotStore(file: file).load() == nil)
    }

    @Test func symbolicLinkIsRejectedForBothLoadAndSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-permission-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target.json")
        try Data("{\"schemaVersion\":1}".utf8).write(to: target)
        let link = directory.appendingPathComponent("permissions.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(PermissionSnapshotStore(file: link).load() == nil)
        #expect(throws: (any Error).self) { try PermissionSnapshotStore(file: link).save(PermissionSnapshot()) }
        #expect(try Data(contentsOf: target) == Data("{\"schemaVersion\":1}".utf8))
    }
}

@MainActor struct PermissionRecoveryTests {
    private func makeStatus(screen: Bool, accessibility: Bool) -> PermissionStatus {
        PermissionStatus(
            readScreenRecording: { screen },
            readAccessibility: { accessibility },
            requestScreenRecordingAction: { false },
            requestAccessibilityAction: { /* Not exercised in this test. */ },
            openScreenRecordingAction: { /* Not exercised in this test. */ },
            openAccessibilityAction: { /* Not exercised in this test. */ })
    }

    @Test func freshUserWithNoSnapshotNeverPromptsButRecordsABaseline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-recovery-fresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("permissions.json")
        let status = makeStatus(screen: false, accessibility: false)
        let prompted = LossBox()
        let recovery = PermissionRecovery(snapshotStore: PermissionSnapshotStore(file: file), status: status) { prompted.value = $0 }
        #expect(!recovery.runStartupCheck(hasCompletedWelcome: true))
        #expect(prompted.value == nil)
        #expect(PermissionSnapshotStore(file: file).load() == PermissionSnapshot())
    }

    @Test func previouslyGrantedNowMissingPromptsOnlyForThosePermissionsOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-recovery-loss-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("permissions.json")
        var seed = PermissionSnapshot()
        seed.lastScreenRecordingGranted = true
        seed.lastAccessibilityGranted = true
        try PermissionSnapshotStore(file: file).save(seed)
        let status = makeStatus(screen: false, accessibility: false)
        let prompts = LossListBox()
        let recovery = PermissionRecovery(snapshotStore: PermissionSnapshotStore(file: file), status: status) { prompts.values.append($0) }
        #expect(recovery.runStartupCheck(hasCompletedWelcome: true))
        #expect(prompts.values == [PermissionLoss(screenRecording: true, accessibility: true)])
        // The marker is consumed; a repeat check in the same run does not prompt again.
        #expect(!recovery.runStartupCheck(hasCompletedWelcome: true))
        #expect(prompts.values.count == 1)
    }

    @Test func onlyTheActuallyLostPermissionIsReported() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-recovery-partial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("permissions.json")
        var seed = PermissionSnapshot()
        seed.lastScreenRecordingGranted = true
        seed.lastAccessibilityGranted = false
        try PermissionSnapshotStore(file: file).save(seed)
        let status = makeStatus(screen: false, accessibility: false)
        let prompted = LossBox()
        let recovery = PermissionRecovery(snapshotStore: PermissionSnapshotStore(file: file), status: status) { prompted.value = $0 }
        #expect(recovery.runStartupCheck(hasCompletedWelcome: true))
        #expect(prompted.value == PermissionLoss(screenRecording: true, accessibility: false))
    }

    @Test func stillGrantedPermissionsAndFirstRunUsersAreNotPrompted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-recovery-quiet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("permissions.json")
        var seed = PermissionSnapshot()
        seed.lastScreenRecordingGranted = true
        seed.lastAccessibilityGranted = true
        try PermissionSnapshotStore(file: file).save(seed)
        // Still granted -> no loss.
        let grantedStatus = makeStatus(screen: true, accessibility: true)
        let prompted = LossBox()
        let grantedRecovery = PermissionRecovery(snapshotStore: PermissionSnapshotStore(file: file), status: grantedStatus) { prompted.value = $0 }
        #expect(!grantedRecovery.runStartupCheck(hasCompletedWelcome: true))
        #expect(prompted.value == nil)
        // A loss on a user still in the first-run welcome flow is not reported either.
        let lostStatus = makeStatus(screen: false, accessibility: false)
        let firstRunRecovery = PermissionRecovery(snapshotStore: PermissionSnapshotStore(file: file), status: lostStatus) { prompted.value = $0 }
        #expect(!firstRunRecovery.runStartupCheck(hasCompletedWelcome: false))
        #expect(prompted.value == nil)
    }

    @Test func grantingAfterLossRecordsTheNewStateForFutureDetection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-recovery-regrant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("permissions.json")
        var seed = PermissionSnapshot()
        seed.lastScreenRecordingGranted = true
        seed.lastAccessibilityGranted = false
        try PermissionSnapshotStore(file: file).save(seed)
        let screen = BoolBox(false)
        let status = PermissionStatus(
            readScreenRecording: { screen.value },
            readAccessibility: { false },
            requestScreenRecordingAction: { false },
            requestAccessibilityAction: { /* Not exercised in this test. */ },
            openScreenRecordingAction: { /* Not exercised in this test. */ },
            openAccessibilityAction: { /* Not exercised in this test. */ })
        let store = PermissionSnapshotStore(file: file)
        let recovery = PermissionRecovery(snapshotStore: store, status: status) { _ in /* Presenter is unused here; only the snapshot side effect is asserted. */ }
        #expect(recovery.runStartupCheck(hasCompletedWelcome: true))
        #expect(store.load()?.lastScreenRecordingGranted == false)
        // Simulate the user granting the permission; the snapshot must advance to granted.
        screen.value = true
        status.refresh()
        #expect(store.load()?.lastScreenRecordingGranted == true)
    }
}
