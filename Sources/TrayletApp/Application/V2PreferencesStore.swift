import Foundation
import Combine
import TrayletCore

enum V2Appearance: String, Codable, CaseIterable, Sendable { case system, light, dark }
enum V2Language: String, Codable, CaseIterable, Sendable { case system, simplifiedChinese, english }

struct V2UserPreferences: Codable, Equatable, Sendable {
    var schemaVersion = 2
    var appearance = V2Appearance.system
    var language = V2Language.system
    var glassEnabled = true
    var hasCompletedWelcome = false
    var shortcuts = V2ShortcutAssignment.defaults
}

/// Reads only an explicitly supplied new-namespace file. Initialization creates no files.
@MainActor final class V2PreferencesStore: ObservableObject {
    @Published private(set) var value = V2UserPreferences()
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
            let decoded = try JSONDecoder().decode(V2UserPreferences.self, from: Data(contentsOf: file))
            guard decoded.schemaVersion == 2, V2ShortcutAssignment.valid(decoded.shortcuts) else { throw FeatureIssue.storage("偏好版本或快捷键无效。") }
            value = decoded
        } catch { failure = "新版本偏好无法读取；原文件已保留。" }
    }

    func save(_ proposed: V2UserPreferences) throws {
        guard failure == nil, proposed.schemaVersion == 2, V2ShortcutAssignment.valid(proposed.shortcuts) else {
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
        let defaults = V2UserPreferences()
        try persist(defaults)
        value = defaults
        failure = nil
    }

    private func persist(_ proposed: V2UserPreferences) throws {
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
