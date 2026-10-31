import Foundation
import Testing
@testable import TrayletApp

@Suite("Clipboard Archive") struct ClipboardArchiveTests {
    private func directory() -> URL { URL(fileURLWithPath: "/private/tmp").appendingPathComponent("traylet-clipboard-" + UUID().uuidString) }
    private func entry(_ text: String = "synthetic archive") -> ClipboardEntry {
        let items: [ClipboardContent] = [.text(text)]
        return ClipboardEntry(id: UUID(), digest: ClipboardPolicy.digest(items), items: items, capturedAt: Date(), favorite: true, application: "synthetic.app")
    }
    @Test func atomicRoundTripPermissionsSettingsAndNoLegacyReads() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("untouched synthetic legacy".utf8).write(to: legacy)
        let archive = V2ClipboardArchive(directory: root); let value = entry()
        #expect(try await archive.load().isEmpty)
        try await archive.replace([value], revision: 1)
        #expect(try await archive.load() == [value])
        let rootMode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("archive.json").path)[.posixPermissions] as? NSNumber
        #expect(rootMode?.intValue == 0o700); #expect(fileMode?.intValue == 0o600)
        var settings = ClipboardSettings(); settings.maximumCount = 1; settings.saveLocally = true
        try await archive.saveSettings(settings)
        #expect(try await archive.loadSettings() == settings)
        try await archive.clear(revision: 2)
        #expect(try String(contentsOf: legacy, encoding: .utf8) == "untouched synthetic legacy")
        #expect(try await archive.load().isEmpty)
    }
    @Test func revisionFencePreventsResurrectionRegardlessOfArrivalOrder() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = V2ClipboardArchive(directory: root); let value = entry()
        try await archive.replace([value], revision: 1)
        try await archive.clear(revision: 20)
        try await archive.replace([value], revision: 19)
        #expect(try await archive.load().isEmpty)
        try await archive.replace([entry("new copy")], revision: 21)
        #expect(try await archive.load().first?.plainText == "new copy")
    }
    @Test func corruptBodyQuarantinesAndExplicitClearRestarts() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = V2ClipboardArchive(directory: root); try await archive.replace([entry()], revision: 1)
        try Data("{broken synthetic archive".utf8).write(to: root.appendingPathComponent("archive.json"))
        await #expect(throws: V2ClipboardArchive.Failure.self) { try await archive.load() }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names.contains(where: { $0.hasPrefix("damaged-") }))
        #expect(!names.contains("archive.json"))
        await #expect(throws: V2ClipboardArchive.Failure.self) { try await archive.replace([entry()], revision: 2) }
        try await archive.clear(revision: 3); try await archive.replace([entry("recovered")], revision: 4)
        #expect(try await archive.load().first?.plainText == "recovered")
    }
    @Test func quarantinedDamageRemainsVisibleAfterReopening() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let damaged = root.appendingPathComponent("damaged-synthetic.json")
        try Data("preserve this damaged body".utf8).write(to: damaged)
        let reopened = V2ClipboardArchive(directory: root)
        await #expect(throws: V2ClipboardArchive.Failure.self) { try await reopened.load() }
        #expect(try String(contentsOf: damaged, encoding: .utf8) == "preserve this damaged body")
    }
    @Test func orphanTempsAreRemovedWithoutInterpretingTheirContents() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let temp = root.appendingPathComponent(".clipboard-crashed.tmp")
        try Data("uncommitted synthetic body".utf8).write(to: temp)
        let archive = V2ClipboardArchive(directory: root)
        #expect(try await archive.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }
    @Test func directoryAndFileSymlinksNeverTouchTargets() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target"); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias"); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let unsafeDirectory = V2ClipboardArchive(directory: alias)
        await #expect(throws: V2ClipboardArchive.Failure.self) { try await unsafeDirectory.replace([entry()], revision: 1) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        let safe = root.appendingPathComponent("safe"); try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        let body = target.appendingPathComponent("synthetic.txt"); try Data("keep synthetic target".utf8).write(to: body)
        try FileManager.default.createSymbolicLink(at: safe.appendingPathComponent("archive.json"), withDestinationURL: body)
        let archive = V2ClipboardArchive(directory: safe)
        await #expect(throws: V2ClipboardArchive.Failure.self) { try await archive.load() }
        await #expect(throws: V2ClipboardArchive.Failure.self) { try await archive.replace([entry()], revision: 1) }
        await #expect(throws: V2ClipboardArchive.Failure.self) { try await archive.clear(revision: 2) }
        #expect(try String(contentsOf: body, encoding: .utf8) == "keep synthetic target")
    }
    @Test func hardLinkedBodyIsRejected() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("external.json"); try Data("synthetic linked body".utf8).write(to: external)
        try FileManager.default.linkItem(at: external, to: root.appendingPathComponent("archive.json"))
        let archive = V2ClipboardArchive(directory: root)
        await #expect(throws: V2ClipboardArchive.Failure.self) { try await archive.load() }
        await #expect(throws: V2ClipboardArchive.Failure.self) { try await archive.replace([entry()], revision: 1) }
        #expect(try String(contentsOf: external, encoding: .utf8) == "synthetic linked body")
    }
}
