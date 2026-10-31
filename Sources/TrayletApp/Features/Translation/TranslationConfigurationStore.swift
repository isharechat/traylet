import Foundation
import Darwin

/// Non-secret v2 preferences, accessed relative to a directory descriptor. Never follows links.
struct TranslationConfigurationStore {
    let url: URL
    private enum StorageFailure: Error { case unsafePath, io }

    func read() throws -> Data? {
        guard let directory = try directory(create: false) else { return nil }
        defer { Darwin.close(directory) }
        guard try hasRegularFile(directory, name: url.lastPathComponent) else { return nil }
        let file = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW)
        guard file >= 0 else { throw StorageFailure.io }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= 64 * 1024 else { throw StorageFailure.io }
        let data = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard data.count <= 64 * 1024 else { throw StorageFailure.io }
        return data
    }

    @discardableResult func write(_ data: Data, preservingOriginal: Bool = false) throws -> URL? {
        guard let directory = try directory(create: true) else { throw StorageFailure.io }
        defer { Darwin.close(directory) }
        _ = try hasRegularFile(directory, name: url.lastPathComponent)
        let temporary = ".translation-\(UUID().uuidString).tmp"
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw StorageFailure.io }
        defer { Darwin.close(file); unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StorageFailure.io }
                offset += count
            }
        }
        guard fchmod(file, 0o600) == 0, fsync(file) == 0 else { throw StorageFailure.io }
        let exists = try hasRegularFile(directory, name: url.lastPathComponent)
        var backup: String?
        if preservingOriginal && exists {
            let name = "translation-\(UUID().uuidString).backup"
            let original = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW)
            guard original >= 0 else { throw StorageFailure.io }
            let restricted = fchmod(original, 0o600) == 0
            Darwin.close(original)
            guard restricted, renameatx_np(directory, url.lastPathComponent, directory, name, UInt32(RENAME_EXCL)) == 0 else { throw StorageFailure.io }
            backup = name
        }
        if renameat(directory, temporary, directory, url.lastPathComponent) != 0 {
            if let backup { _ = renameatx_np(directory, backup, directory, url.lastPathComponent, UInt32(RENAME_EXCL)) }
            throw StorageFailure.io // Original is restored when possible; otherwise its unique backup remains.
        }
        return backup.map { url.deletingLastPathComponent().appendingPathComponent($0) }
    }

    private func hasRegularFile(_ directory: Int32, name: String) throws -> Bool {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return false }
            throw StorageFailure.io
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { throw StorageFailure.unsafePath }
        return true
    }

    private func directory(create: Bool) throws -> Int32? {
        // macOS system aliases are trusted; user-controlled path components remain no-follow.
        var path = url.deletingLastPathComponent().standardizedFileURL.path
        if path == "/tmp" || path.hasPrefix("/tmp/") { path = "/private" + path }
        if path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard current >= 0 else { throw StorageFailure.io }
        do {
            for component in path.split(separator: "/") {
                let name = String(component)
                var next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if next < 0 && errno == ENOENT && create {
                    guard mkdirat(current, name, 0o700) == 0 || errno == EEXIST else { throw StorageFailure.io }
                    next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                }
                if next < 0 && errno == ENOENT && !create { Darwin.close(current); return nil }
                guard next >= 0 else { throw StorageFailure.unsafePath }
                Darwin.close(current); current = next
            }
            var info = stat()
            guard fstat(current, &info) == 0, info.st_uid == getuid() else { throw StorageFailure.unsafePath }
            if create { guard fchmod(current, 0o700) == 0 else { throw StorageFailure.io } }
            return current
        } catch { Darwin.close(current); throw error }
    }
}
