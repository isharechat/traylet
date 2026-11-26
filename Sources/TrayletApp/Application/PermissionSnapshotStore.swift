import Foundation
import TrayletCore

/// Persisted record of the last known permission state. It stores only two booleans;
/// never any user content, and never data from a previous Traylet version.
struct PermissionSnapshot: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var lastScreenRecordingGranted = false
    var lastAccessibilityGranted = false
}

/// Reads and writes `~/Library/Application Support/Traylet/v2/permissions.json` with the same
/// hardening as `PreferencesStore`: size cap, symbolic-link rejection, directory 0700 / file 0600.
/// A missing or damaged file reads as `nil` (no snapshot) and is never silently deleted.
@MainActor final class PermissionSnapshotStore {
    static let maximumBytes = 4_096
    private let file: URL?

    init(file: URL? = nil) {
        self.file = file
    }

    func load() -> PermissionSnapshot? {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            try Self.rejectSymbolicLink(file)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let bytes = attributes[.size] as? NSNumber, bytes.intValue <= Self.maximumBytes else { return nil }
            let decoded = try JSONDecoder().decode(PermissionSnapshot.self, from: Data(contentsOf: file))
            guard decoded.schemaVersion == 1 else { return nil }
            return decoded
        } catch { return nil }
    }

    func save(_ snapshot: PermissionSnapshot) throws {
        guard let file else { return }
        try Self.rejectSymbolicLink(file)
        try Self.rejectSymbolicLink(file.deletingLastPathComponent())
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func rejectSymbolicLink(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { throw FeatureIssue.storage("权限快照路径不能是符号链接。") }
    }
}
