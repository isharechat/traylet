import Foundation
import Combine
import TrayletCore

enum Appearance: String, Codable, CaseIterable, Sendable { case system, light, dark }
enum Language: String, Codable, CaseIterable, Sendable { case system, simplifiedChinese, english }

struct UserPreferences: Codable, Equatable, Sendable {
    var schemaVersion = 2
    var appearance = Appearance.system
    var language = Language.system
    var glassEnabled = true
    var hasCompletedWelcome = false
    var shortcuts = ShortcutAssignment.defaults
    var autoCheckUpdates = true
    var includePreviewUpdates = true
    var skippedUpdateTag: String? = nil

    init(
        schemaVersion: Int = 2,
        appearance: Appearance = .system,
        language: Language = .system,
        glassEnabled: Bool = true,
        hasCompletedWelcome: Bool = false,
        shortcuts: [ShortcutAssignment] = ShortcutAssignment.defaults,
        autoCheckUpdates: Bool = true,
        includePreviewUpdates: Bool = true,
        skippedUpdateTag: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.appearance = appearance
        self.language = language
        self.glassEnabled = glassEnabled
        self.hasCompletedWelcome = hasCompletedWelcome
        self.shortcuts = shortcuts
        self.autoCheckUpdates = autoCheckUpdates
        self.includePreviewUpdates = includePreviewUpdates
        self.skippedUpdateTag = skippedUpdateTag
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
        language = try container.decodeIfPresent(Language.self, forKey: .language) ?? .system
        glassEnabled = try container.decodeIfPresent(Bool.self, forKey: .glassEnabled) ?? true
        hasCompletedWelcome = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedWelcome) ?? false
        let decodedShortcuts = try container.decodeIfPresent([ShortcutAssignment].self, forKey: .shortcuts) ?? ShortcutAssignment.defaults
        shortcuts = Self.mergeMissingShortcuts(decodedShortcuts)
        autoCheckUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? true
        includePreviewUpdates = try container.decodeIfPresent(Bool.self, forKey: .includePreviewUpdates) ?? true
        skippedUpdateTag = try container.decodeIfPresent(String.self, forKey: .skippedUpdateTag)
    }

    private static func mergeMissingShortcuts(_ existing: [ShortcutAssignment]) -> [ShortcutAssignment] {
        var merged = existing
        var usedChords = Set(existing.compactMap(\.chord))
        for action in Action.allCases where !merged.contains(where: { $0.action == action }) {
            let defaultChord = ShortcutAssignment.defaults.first(where: { $0.action == action })?.chord
            let assignedChord = defaultChord.flatMap { usedChords.contains($0) ? nil : $0 }
            if let assignedChord { usedChords.insert(assignedChord) }
            merged.append(.init(action: action, chord: assignedChord))
        }
        return merged
    }
}

/// Reads only an explicitly supplied new-namespace file. Initialization creates no files.
@MainActor final class PreferencesStore: ObservableObject {
    @Published private(set) var value = UserPreferences()
    @Published private(set) var failure: String?
    private let file: URL?

    init(file: URL? = nil) {
        self.file = file
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try rejectSymbolicLink(file)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 65_536 else {
                throw FeatureIssue.storage("偏好文件过大。")
            }
            let decoded = try JSONDecoder().decode(UserPreferences.self, from: Data(contentsOf: file))
            guard decoded.schemaVersion == 2, ShortcutAssignment.valid(decoded.shortcuts) else { throw FeatureIssue.storage("偏好版本或快捷键无效。") }
            value = decoded
        } catch { failure = "新版本偏好无法读取；原文件已保留。" }
    }

    func save(_ proposed: UserPreferences) throws {
        guard failure == nil, proposed.schemaVersion == 2, ShortcutAssignment.valid(proposed.shortcuts) else {
            throw FeatureIssue.storage("偏好未保存；请先处理保留的损坏文件。")
        }
        try persist(proposed)
        value = proposed
    }

    /// Called only after a user confirms recovery; preserve the damaged new file as a backup.
    func resetPreservingDamagedFile() throws {
        if let file, FileManager.default.fileExists(atPath: file.path) {
            try rejectSymbolicLink(file)
            let backup = file.appendingPathExtension("recovery-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: file, to: backup)
        }
        let defaults = UserPreferences()
        try persist(defaults)
        value = defaults
        failure = nil
    }

    private func persist(_ proposed: UserPreferences) throws {
        guard let file else { return }
        try rejectSymbolicLink(file)
        try rejectSymbolicLink(file.deletingLastPathComponent())
        let data = try JSONEncoder().encode(proposed)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func rejectSymbolicLink(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { throw FeatureIssue.storage("偏好路径不能是符号链接。") }
    }
}
