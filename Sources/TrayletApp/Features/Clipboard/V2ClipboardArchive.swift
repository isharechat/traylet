import Foundation
import Darwin

protocol V2ClipboardArchiving: Sendable {
    func load() async throws -> [ClipboardEntry]
    func replace(_ entries: [ClipboardEntry], revision: UInt64) async throws
    func clear(revision: UInt64) async throws
    func loadSettings() async throws -> ClipboardSettings?
    func saveSettings(_ settings: ClipboardSettings) async throws
    /// Favorites live in their own file so they survive even when full-history saving is off.
    func loadFavorites() async throws -> [ClipboardEntry]
    func replaceFavorites(_ entries: [ClipboardEntry], revision: UInt64) async throws
    func clearFavorites(revision: UInt64) async throws
}

/// An actor orders every write. Revision fencing prevents a delayed snapshot from reviving a cleared body.
actor V2ClipboardArchive: V2ClipboardArchiving {
    enum Failure: Error { case unsafePath, io, damaged }
    private struct Envelope: Codable { let version: Int; let entries: [ClipboardEntry] }
    let directory: URL
    private var latestRevision: UInt64 = 0
    private var latestFavoritesRevision: UInt64 = 0
    static let favoritesLimit = 200
    private var damaged = false
    init(directory: URL) { self.directory = directory }

    func load() throws -> [ClipboardEntry] {
        let dir = try openDirectory(); defer { Darwin.close(dir) }
        try cleanTemporaryFiles(dir)
        if try names(dir).contains(where: { $0.hasPrefix("damaged-") && $0.hasSuffix(".json") }) { damaged = true; throw Failure.damaged }
        let fd = openat(dir, "archive.json", O_RDONLY | O_NOFOLLOW)
        if fd < 0 && errno == ENOENT { return [] }
        guard fd >= 0 else { throw Failure.unsafePath }; defer { Darwin.close(fd) }
        let data: Data
        do { data = try read(fd, limit: 48 * 1_024 * 1_024) }
        catch { damaged = true; throw error }
        do {
            let value = try JSONDecoder().decode(Envelope.self, from: data)
            guard value.version == 2, value.entries.count <= 1000,
                  value.entries.allSatisfy({ ClipboardPolicy.valid($0.items) && $0.digest == ClipboardPolicy.digest($0.items) }),
                  Set(value.entries.map(\.id)).count == value.entries.count,
                  Set(value.entries.map(\.digest)).count == value.entries.count,
                  value.entries.reduce(0, { $0 + $1.byteCount }) <= ClipboardPolicy.totalBytes else { throw Failure.damaged }
            return value.entries
        } catch {
            damaged = true
            guard renameat(dir, "archive.json", dir, "damaged-\(UUID().uuidString).json") == 0 else { throw Failure.io }
            throw Failure.damaged
        }
    }
    func replace(_ entries: [ClipboardEntry], revision: UInt64) throws {
        guard revision > latestRevision else { return }; latestRevision = revision
        guard !damaged else { throw Failure.damaged }
        guard entries.count <= 1000, entries.allSatisfy({ ClipboardPolicy.valid($0.items) && $0.digest == ClipboardPolicy.digest($0.items) }),
              entries.reduce(0, { $0 + $1.byteCount }) <= ClipboardPolicy.totalBytes else { throw Failure.damaged }
        let dir = try openDirectory(); defer { Darwin.close(dir) }
        if try names(dir).contains(where: { $0.hasPrefix("damaged-") && $0.hasSuffix(".json") }) { damaged = true; throw Failure.damaged }
        try atomicWrite(JSONEncoder().encode(Envelope(version: 2, entries: entries)), name: "archive.json", directory: dir)
    }
    func clear(revision: UInt64) throws {
        guard revision > latestRevision else { return }; latestRevision = revision
        let dir = try openDirectory(); defer { Darwin.close(dir) }
        try remove("archive.json", directory: dir)
        for name in try names(dir) where name.hasPrefix("damaged-") && name.hasSuffix(".json") { try remove(name, directory: dir) }
        try cleanTemporaryFiles(dir)
        guard fsync(dir) == 0 else { throw Failure.io }; damaged = false
    }
    func loadFavorites() throws -> [ClipboardEntry] {
        let dir = try openDirectory(); defer { Darwin.close(dir) }
        try cleanTemporaryFiles(dir)
        let fd = openat(dir, "favorites.json", O_RDONLY | O_NOFOLLOW)
        if fd < 0 && errno == ENOENT { return [] }
        guard fd >= 0 else { throw Failure.unsafePath }; defer { Darwin.close(fd) }
        let data = try read(fd, limit: 48 * 1_024 * 1_024)
        do {
            let value = try JSONDecoder().decode(Envelope.self, from: data)
            guard value.version == 2, value.entries.count <= Self.favoritesLimit,
                  value.entries.allSatisfy({ $0.favorite && ClipboardPolicy.valid($0.items) && $0.digest == ClipboardPolicy.digest($0.items) }),
                  Set(value.entries.map(\.id)).count == value.entries.count,
                  Set(value.entries.map(\.digest)).count == value.entries.count,
                  value.entries.reduce(0, { $0 + $1.byteCount }) <= ClipboardPolicy.totalBytes else { throw Failure.damaged }
            return value.entries
        } catch {
            // Quarantine under a name the history archive ignores, so a bad favorites file never blocks history.
            guard renameat(dir, "favorites.json", dir, "favorites-damaged-\(UUID().uuidString).json") == 0 else { throw Failure.io }
            throw Failure.damaged
        }
    }
    func replaceFavorites(_ entries: [ClipboardEntry], revision: UInt64) throws {
        guard revision > latestFavoritesRevision else { return }; latestFavoritesRevision = revision
        guard entries.count <= Self.favoritesLimit, entries.allSatisfy({ $0.favorite && ClipboardPolicy.valid($0.items) && $0.digest == ClipboardPolicy.digest($0.items) }),
              entries.reduce(0, { $0 + $1.byteCount }) <= ClipboardPolicy.totalBytes else { throw Failure.damaged }
        let dir = try openDirectory(); defer { Darwin.close(dir) }
        try atomicWrite(JSONEncoder().encode(Envelope(version: 2, entries: entries)), name: "favorites.json", directory: dir)
    }
    func clearFavorites(revision: UInt64) throws {
        guard revision > latestFavoritesRevision else { return }; latestFavoritesRevision = revision
        let dir = try openDirectory(); defer { Darwin.close(dir) }
        try remove("favorites.json", directory: dir)
        for name in try names(dir) where name.hasPrefix("favorites-damaged-") && name.hasSuffix(".json") { try remove(name, directory: dir) }
        guard fsync(dir) == 0 else { throw Failure.io }
    }
    func loadSettings() throws -> ClipboardSettings? {
        let dir = try openDirectory(); defer { Darwin.close(dir) }
        let fd = openat(dir, "preferences.json", O_RDONLY | O_NOFOLLOW)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw Failure.unsafePath }; defer { Darwin.close(fd) }
        var settings = try JSONDecoder().decode(ClipboardSettings.self, from: read(fd, limit: 64 * 1024))
        settings.normalize(); return settings
    }
    func saveSettings(_ settings: ClipboardSettings) throws {
        let dir = try openDirectory(); defer { Darwin.close(dir) }
        try atomicWrite(JSONEncoder().encode(settings), name: "preferences.json", directory: dir)
    }
    /// Every path component is opened relative to a trusted descriptor, with no symlink traversal.
    /// Keeping the descriptor pins the directory if another process renames a parent during a save.
    private func openDirectory() throws -> Int32 {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.pathComponents.contains("..") else { throw Failure.unsafePath }
        var components = Array(directory.pathComponents.dropFirst())
        // Darwin's system temporary URLs use /var (and callers commonly use /tmp).
        // Recognize only these fixed root aliases; never resolve caller-controlled descendants.
        if let first = components.first, first == "var" || first == "tmp",
           let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/" + first),
           target == "private/" + first || target == "/private/" + first {
            components.insert("private", at: 0)
        }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard current >= 0 else { throw Failure.io }
        do {
            for component in components {
                var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if next < 0 && errno == ENOENT {
                    guard mkdirat(current, component, 0o700) == 0 || errno == EEXIST else { throw Failure.io }
                    next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                }
                guard next >= 0 else { throw Failure.unsafePath }
                Darwin.close(current); current = next
            }
            var info = stat()
            guard fstat(current, &info) == 0, info.st_uid == getuid(), fchmod(current, 0o700) == 0 else { throw Failure.unsafePath }
            return current
        } catch { Darwin.close(current); throw error }
    }
    private func read(_ fd: Int32, limit: Int) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= limit, info.st_nlink == 1, fchmod(fd, 0o600) == 0 else { throw Failure.unsafePath }
        // Bound the read even if another process grows the already-open regular file.
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw Failure.unsafePath }; return data
    }
    private func names(_ dir: Int32) throws -> [String] {
        let copy = dup(dir); guard copy >= 0 else { throw Failure.io }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw Failure.io }; defer { closedir(stream) }
        // dup shares the directory offset; every independent scan starts from the beginning.
        rewinddir(stream)
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
        }
        return result
    }
    private func ensureRegularOrAbsent(_ name: String, directory dir: Int32) throws {
        var info = stat()
        if fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw Failure.io }; return
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { throw Failure.unsafePath }
    }
    private func remove(_ name: String, directory dir: Int32) throws {
        try ensureRegularOrAbsent(name, directory: dir)
        guard unlinkat(dir, name, 0) == 0 || errno == ENOENT else { throw Failure.io }
    }
    private func cleanTemporaryFiles(_ dir: Int32) throws {
        for name in try names(dir) where name.hasPrefix(".clipboard-") && name.hasSuffix(".tmp") { try remove(name, directory: dir) }
    }
    private func atomicWrite(_ data: Data, name: String, directory dir: Int32) throws {
        try ensureRegularOrAbsent(name, directory: dir)
        let temporary = ".clipboard-\(UUID().uuidString).tmp"
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.io }; defer { Darwin.close(fd); unlinkat(dir, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.io }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Failure.io }
        try ensureRegularOrAbsent(name, directory: dir)
        guard renameat(dir, temporary, dir, name) == 0, fsync(dir) == 0 else { throw Failure.io }
    }
}
