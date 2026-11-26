import AppKit
import Combine
import CryptoKit
import Foundation
import TrayletCore

struct AppVersion: Comparable, Equatable, Sendable {
    var major: Int
    var minor: Int
    var patch: Int
    var beta: Int?
    var build: Int?
    var isPreview: Bool

    init(major: Int, minor: Int, patch: Int, beta: Int? = nil, build: Int? = nil, isPreview: Bool = false) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.beta = beta
        self.build = build
        self.isPreview = isPreview
    }

    init?(string: String, build: Int? = nil) {
        var raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("v") || raw.hasPrefix("V") {
            raw.removeFirst()
        }
        var preview = false
        if raw.hasSuffix("-preview") {
            preview = true
            raw.removeLast("-preview".count)
        }
        let parts = raw.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let coreParts = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard coreParts.count == 3,
              let major = Int(coreParts[0]),
              let minor = Int(coreParts[1]),
              let patch = Int(coreParts[2]) else {
            return nil
        }
        var betaNumber: Int?
        if parts.count == 2 {
            let suffix = String(parts[1])
            guard suffix.hasPrefix("beta."), let value = Int(suffix.dropFirst("beta.".count)) else {
                return nil
            }
            betaNumber = value
        }
        self.init(major: major, minor: minor, patch: patch, beta: betaNumber, build: build, isPreview: preview)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.beta, rhs.beta) {
        case (nil, nil):
            break
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case let (.some(l), .some(r)):
            if l != r { return l < r }
        }
        if let lBuild = lhs.build, let rBuild = rhs.build, lBuild != rBuild {
            return lBuild < rBuild
        }
        return false
    }
}

struct UpdateRelease: Equatable, Sendable {
    let tagName: String
    let version: AppVersion
    let displayVersion: String
    let htmlURL: URL
    let downloadURL: URL?
    let sha256URL: URL?
    let releaseNotes: String
    let isPrerelease: Bool
    let publishedAt: String?

    private struct GitHubReleaseDTO: Decodable {
        struct AssetDTO: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let name: String?
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let htmlURL: URL
        let publishedAt: String?
        let assets: [AssetDTO]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case draft
            case prerelease
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case assets
        }
    }

    static func parseReleases(from data: Data, includePreview: Bool) throws -> [UpdateRelease] {
        let decoded = try JSONDecoder().decode([GitHubReleaseDTO].self, from: data)
        var results: [UpdateRelease] = []
        for dto in decoded where !dto.draft {
            guard var version = AppVersion(string: dto.tagName) else { continue }
            let prerelease = dto.prerelease || version.beta != nil || version.isPreview
            if !includePreview && prerelease { continue }

            let zipAsset = dto.assets.first {
                $0.name.hasPrefix("Traylet-macos-arm64-") && $0.name.hasSuffix(".zip")
            }
            let shaAsset: GitHubReleaseDTO.AssetDTO?
            if let zipAsset {
                shaAsset = dto.assets.first { $0.name == "\(zipAsset.name).sha256" }
                    ?? dto.assets.first { $0.name.hasPrefix("Traylet-macos-arm64-") && $0.name.hasSuffix(".zip.sha256") }
                if let extractedBuild = extractBuildNumber(from: zipAsset.name) {
                    version.build = extractedBuild
                }
            } else {
                shaAsset = nil
            }

            let display = dto.tagName.hasPrefix("v") ? String(dto.tagName.dropFirst()) : dto.tagName
            results.append(UpdateRelease(
                tagName: dto.tagName,
                version: version,
                displayVersion: display,
                htmlURL: dto.htmlURL,
                downloadURL: zipAsset?.browserDownloadURL,
                sha256URL: shaAsset?.browserDownloadURL,
                releaseNotes: dto.body ?? "",
                isPrerelease: prerelease,
                publishedAt: dto.publishedAt
            ))
        }
        return results.sorted { $0.version > $1.version }
    }

    private static func extractBuildNumber(from assetName: String) -> Int? {
        guard let range = assetName.range(of: #"-build(\d+)\.zip$"#, options: .regularExpression) else {
            return nil
        }
        let matched = assetName[range]
        let digits = matched.dropFirst("-build".count).dropLast(".zip".count)
        return Int(digits)
    }
}

enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(Date)
    case available(UpdateRelease)
    case downloading(UpdateRelease)
    case readyToInstall(UpdateRelease, stagedAppURL: URL, canReplaceInPlace: Bool)
    case failed(String)
}

protocol UpdateTransport: Sendable {
    func fetchData(from url: URL) async throws -> Data
    func downloadFile(from url: URL, to destination: URL) async throws
}

struct URLSessionUpdateTransport: UpdateTransport {
    private let userAgent: String

    init(userAgent: String = URLSessionUpdateTransport.defaultUserAgent()) {
        self.userAgent = userAgent
    }

    private static func defaultUserAgent() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "TrayletReleaseVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
        return "Traylet/\(version)"
    }

    func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FeatureIssue.unavailable("更新服务返回状态码 \(http.statusCode)。")
        }
        return data
    }

    func downloadFile(from url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FeatureIssue.unavailable("下载更新包失败（状态码 \(http.statusCode)）。")
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)
    }
}

protocol UpdateInstalling: Sendable {
    func verifyAndUnpack(zipURL: URL, expectedSHA256: String, into stagingDirectory: URL) throws -> URL
    func canReplaceRunningApp(currentAppURL: URL?) -> Bool
    func installAndRelaunch(stagedAppURL: URL, targetAppURL: URL, currentPID: Int32) throws
    func revealInFinder(_ url: URL)
    func openURL(_ url: URL)
}

struct SystemUpdateInstaller: UpdateInstalling {
    func verifyAndUnpack(zipURL: URL, expectedSHA256: String, into stagingDirectory: URL) throws -> URL {
        let actual = try sha256Hex(of: zipURL)
        let normalizedExpected = expectedSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard actual == normalizedExpected else {
            throw FeatureIssue.unavailable("更新包 SHA-256 校验失败，已中止安装。")
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: stagingDirectory.path) {
            try fm.removeItem(at: stagingDirectory)
        }
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        try runProcess("/usr/bin/ditto", arguments: ["-x", "-k", zipURL.path, stagingDirectory.path])

        let directApp = stagingDirectory.appendingPathComponent("Traylet.app", isDirectory: true)
        let appURL: URL
        if fm.fileExists(atPath: directApp.path) {
            appURL = directApp
        } else {
            let entries = try fm.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)
            guard let found = entries.first(where: { $0.pathExtension == "app" }) else {
                throw FeatureIssue.unavailable("更新包内未找到 Traylet.app。")
            }
            appURL = found
        }

        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let infoData = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              (plist["CFBundleIdentifier"] as? String) == "local.traylet.app" else {
            throw FeatureIssue.unavailable("更新包应用标识无效。")
        }

        try runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", appURL.path])
        return appURL
    }

    func canReplaceRunningApp(currentAppURL: URL?) -> Bool {
        guard let url = currentAppURL else { return false }
        let path = url.path
        guard url.pathExtension == "app", !path.contains("/.build/") else { return false }
        let parent = url.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: parent.path)
    }

    func installAndRelaunch(stagedAppURL: URL, targetAppURL: URL, currentPID: Int32) throws {
        let backupURL = targetAppURL.deletingLastPathComponent()
            .appendingPathComponent(".\(targetAppURL.lastPathComponent).backup-\(UUID().uuidString)")
        let script = """
        pid="$1"
        staged="$2"
        target="$3"
        backup="$4"
        while /bin/kill -0 "$pid" 2>/dev/null; do
          /bin/sleep 0.2
        done
        if [ -d "$target" ]; then
          /bin/mv "$target" "$backup" || exit 1
        fi
        if /bin/mv "$staged" "$target"; then
          /bin/rm -rf "$backup"
          /usr/bin/open "$target"
        else
          if [ -d "$backup" ]; then
            /bin/mv "$backup" "$target"
          fi
          exit 1
        fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "traylet-updater", "\(currentPID)", stagedAppURL.path, targetAppURL.path, backupURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func runProcess(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw FeatureIssue.unavailable(errText.isEmpty ? "校验或解包失败。" : errText)
        }
    }
}

@MainActor final class UpdateController: ObservableObject {
    static let defaultFeedURL = URL(string: "https://api.github.com/repos/isharechat/traylet/releases?per_page=10")!

    @Published private(set) var state: UpdateState = .idle
    @Published private(set) var lastCheckedAt: Date?

    private let preferences: PreferencesStore
    private let actions: SettingsActions
    private let transport: any UpdateTransport
    private let installer: any UpdateInstalling
    private let feedURL: URL
    private let currentVersion: AppVersion
    private let currentBundleURL: () -> URL?
    private let stagingRoot: URL
    private var automaticTask: Task<Void, Never>?
    private var observation: AnyCancellable?

    init(
        preferences: PreferencesStore,
        actions: SettingsActions,
        transport: any UpdateTransport = URLSessionUpdateTransport(),
        installer: any UpdateInstalling = SystemUpdateInstaller(),
        feedURL: URL? = nil,
        currentVersion: AppVersion? = nil,
        currentBundleURL: @escaping () -> URL? = { Bundle.main.bundleURL },
        stagingRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-updates", isDirectory: true)
    ) {
        self.preferences = preferences
        self.actions = actions
        self.transport = transport
        self.installer = installer
        self.currentBundleURL = currentBundleURL
        self.stagingRoot = stagingRoot

        if let feedURL {
            self.feedURL = feedURL
        } else if let rawFeed = Bundle.main.object(forInfoDictionaryKey: "TrayletUpdateFeedURL") as? String,
                  let parsedFeed = URL(string: rawFeed) {
            self.feedURL = parsedFeed
        } else {
            self.feedURL = Self.defaultFeedURL
        }

        if let currentVersion {
            self.currentVersion = currentVersion
        } else {
            let versionString = Bundle.main.object(forInfoDictionaryKey: "TrayletReleaseVersion") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "0.1.0-beta.3"
            let buildInt = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init)
            self.currentVersion = AppVersion(string: versionString, build: buildInt)
                ?? AppVersion(major: 0, minor: 1, patch: 0, beta: 3, build: buildInt)
        }

        self.observation = preferences.$value
            .map(\.autoCheckUpdates)
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.startAutomaticCheckIfNeeded()
                } else {
                    self.stopAutomaticChecks()
                }
            }
    }

    func startAutomaticCheckIfNeeded() {
        guard preferences.value.autoCheckUpdates, preferences.value.hasCompletedWelcome else { return }
        guard automaticTask == nil else { return }
        automaticTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkForUpdates(manual: false)
                try? await Task.sleep(nanoseconds: 86_400_000_000_000)
            }
        }
    }

    func stopAutomaticChecks() {
        automaticTask?.cancel()
        automaticTask = nil
    }

    func checkForUpdates(manual: Bool) async {
        switch state {
        case .checking, .downloading:
            return
        default:
            break
        }
        state = .checking
        do {
            let data = try await transport.fetchData(from: feedURL)
            let releases = try UpdateRelease.parseReleases(from: data, includePreview: preferences.value.includePreviewUpdates)
            let now = Date()
            lastCheckedAt = now
            if let newest = releases.first, newest.version > currentVersion {
                if !manual && newest.tagName == preferences.value.skippedUpdateTag {
                    state = .upToDate(now)
                } else {
                    state = .available(newest)
                }
            } else {
                state = .upToDate(now)
            }
        } catch {
            if manual {
                let message = (error as? FeatureIssue)?.localizedDescription ?? error.localizedDescription
                state = .failed(message)
            } else {
                state = .idle
            }
        }
    }

    func downloadUpdate() async {
        guard case .available(let release) = state else { return }
        guard let downloadURL = release.downloadURL, let shaURL = release.sha256URL else {
            state = .failed("该版本未提供完整的更新包与 SHA-256 校验文件，请在 GitHub 查看。")
            return
        }
        state = .downloading(release)
        do {
            let fm = FileManager.default
            let workDir = stagingRoot.appendingPathComponent(release.tagName, isDirectory: true)
            if fm.fileExists(atPath: workDir.path) {
                try fm.removeItem(at: workDir)
            }
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

            let shaData = try await transport.fetchData(from: shaURL)
            guard let expectedSHA = Self.parseSHA256Hex(from: shaData) else {
                throw FeatureIssue.unavailable("无法解析更新包的 SHA-256 校验值。")
            }

            let zipURL = workDir.appendingPathComponent(downloadURL.lastPathComponent)
            try await transport.downloadFile(from: downloadURL, to: zipURL)

            let unpackDir = workDir.appendingPathComponent("unpacked", isDirectory: true)
            let stagedApp = try installer.verifyAndUnpack(zipURL: zipURL, expectedSHA256: expectedSHA, into: unpackDir)
            let canReplace = installer.canReplaceRunningApp(currentAppURL: currentBundleURL())
            state = .readyToInstall(release, stagedAppURL: stagedApp, canReplaceInPlace: canReplace)
        } catch {
            let message = (error as? FeatureIssue)?.localizedDescription ?? error.localizedDescription
            state = .failed(message)
        }
    }

    func installStagedUpdate(requestQuit: @MainActor () -> Void) {
        guard case .readyToInstall(_, let stagedAppURL, let canReplaceInPlace) = state else { return }
        if canReplaceInPlace, let targetURL = currentBundleURL() {
            do {
                try installer.installAndRelaunch(
                    stagedAppURL: stagedAppURL,
                    targetAppURL: targetURL,
                    currentPID: ProcessInfo.processInfo.processIdentifier
                )
                requestQuit()
            } catch {
                let message = (error as? FeatureIssue)?.localizedDescription ?? error.localizedDescription
                state = .failed(message)
            }
        } else {
            installer.revealInFinder(stagedAppURL)
        }
    }

    func openReleasePage(_ release: UpdateRelease) {
        installer.openURL(release.htmlURL)
    }

    func skipVersion(_ release: UpdateRelease) {
        actions.setSkippedUpdateTag(release.tagName)
        state = .upToDate(lastCheckedAt ?? Date())
    }

    static func parseSHA256Hex(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let token = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard token.count == 64, token.allSatisfy(\.isHexDigit) else { return nil }
        return token.lowercased()
    }
}
