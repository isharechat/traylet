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
        guard let file else { return nil }
        do {
            guard let data = try TranslationConfigurationStore(url: file, maxBytes: Self.maximumBytes).read() else { return nil }
            let decoded = try JSONDecoder().decode(PermissionSnapshot.self, from: data)
            guard decoded.schemaVersion == 1 else { return nil }
            return decoded
        } catch { return nil }
    }

    func save(_ snapshot: PermissionSnapshot) throws {
        guard let file else { return }
        let data = try JSONEncoder().encode(snapshot)
        try TranslationConfigurationStore(url: file, maxBytes: Self.maximumBytes).write(data)
    }
}
