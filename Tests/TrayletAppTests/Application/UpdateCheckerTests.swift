import CryptoKit
import Foundation
import Testing
@testable import TrayletApp
import TrayletCore

@Suite("Open-Source Update Checker")
@MainActor
struct UpdateCheckerTests {
    @Test func versionParsingAndComparisonRules() {
        let beta3 = AppVersion(string: "0.1.0-beta.3", build: 3)
        let beta4Preview = AppVersion(string: "v0.1.0-beta.4-preview", build: 4)
        let release010 = AppVersion(string: "v0.1.0")
        let release020 = AppVersion(string: "0.2.0")

        #expect(beta3 != nil)
        #expect(beta4Preview != nil)
        #expect(beta4Preview?.isPreview == true)
        #expect(release010 != nil)
        #expect(release020 != nil)

        #expect(beta3! < beta4Preview!)
        #expect(beta4Preview! < release010!)
        #expect(release010! < release020!)

        let sameBetaBuild3 = AppVersion(string: "v0.1.0-beta.3", build: 3)!
        let sameBetaBuild4 = AppVersion(string: "v0.1.0-beta.3", build: 4)!
        #expect(sameBetaBuild3 < sameBetaBuild4)
    }

    @Test func parseReleasesFiltersDraftsAndPreviews() throws {
        let json = """
        [
          {
            "tag_name": "v0.2.0-draft",
            "draft": true,
            "prerelease": false,
            "html_url": "https://github.com/isharechat/traylet/releases/tag/v0.2.0-draft",
            "assets": []
          },
          {
            "tag_name": "v0.1.0-beta.5-preview",
            "draft": false,
            "prerelease": true,
            "body": "Preview release",
            "html_url": "https://github.com/isharechat/traylet/releases/tag/v0.1.0-beta.5-preview",
            "assets": [
              {
                "name": "Traylet-macos-arm64-v0.1.0-beta.5-build5.zip",
                "browser_download_url": "https://example.com/Traylet-v0.1.0-beta.5-build5.zip"
              },
              {
                "name": "Traylet-macos-arm64-v0.1.0-beta.5-build5.zip.sha256",
                "browser_download_url": "https://example.com/Traylet-v0.1.0-beta.5-build5.zip.sha256"
              }
            ]
          },
          {
            "tag_name": "v0.1.0",
            "draft": false,
            "prerelease": false,
            "body": "Stable release",
            "html_url": "https://github.com/isharechat/traylet/releases/tag/v0.1.0",
            "assets": []
          }
        ]
        """
        let data = Data(json.utf8)

        let withPreview = try UpdateRelease.parseReleases(from: data, includePreview: true)
        #expect(withPreview.count == 2)
        #expect(withPreview.first?.tagName == "v0.1.0")
        #expect(withPreview.last?.version.build == 5)
        #expect(withPreview.last?.downloadURL?.absoluteString == "https://example.com/Traylet-v0.1.0-beta.5-build5.zip")
        #expect(withPreview.last?.sha256URL?.absoluteString == "https://example.com/Traylet-v0.1.0-beta.5-build5.zip.sha256")

        let stableOnly = try UpdateRelease.parseReleases(from: data, includePreview: false)
        #expect(stableOnly.count == 1)
        #expect(stableOnly.first?.tagName == "v0.1.0")
    }

    @Test func skipVersionSuppressesSilentCheckButShowsOnManualCheck() async {
        let payload = """
        [
          {
            "tag_name": "v0.1.0-beta.4-preview",
            "draft": false,
            "prerelease": true,
            "body": "Notes",
            "html_url": "https://github.com/isharechat/traylet/releases/tag/v0.1.0-beta.4-preview",
            "assets": []
          }
        ]
        """
        let transport = MockUpdateTransport(feedData: Data(payload.utf8))
        let store = PreferencesStore()
        let actions = SettingsActions(preferences: store, login: StubLogin())
        let controller = UpdateController(
            preferences: store,
            actions: actions,
            transport: transport,
            installer: MockUpdateInstaller(),
            currentVersion: AppVersion(string: "0.1.0-beta.3", build: 3)!
        )

        await controller.checkForUpdates(manual: true)
        guard case .available(let release) = controller.state else {
            Issue.record("Expected .available state")
            return
        }

        controller.skipVersion(release)
        #expect(store.value.skippedUpdateTag == "v0.1.0-beta.4-preview")

        await controller.checkForUpdates(manual: false)
        if case .upToDate = controller.state {
        } else {
            Issue.record("Expected silent check to stay .upToDate for skipped version")
        }

        await controller.checkForUpdates(manual: true)
        if case .available(let manualRelease) = controller.state {
            #expect(manualRelease.tagName == "v0.1.0-beta.4-preview")
        } else {
            Issue.record("Expected manual check to surface skipped version")
        }
    }

    @Test func networkFailureResetsToIdleOnSilentAndFailsOnManual() async {
        let transport = MockUpdateTransport(feedError: FeatureIssue.unavailable("离线"))
        let store = PreferencesStore()
        let actions = SettingsActions(preferences: store, login: StubLogin())
        let controller = UpdateController(
            preferences: store,
            actions: actions,
            transport: transport,
            installer: MockUpdateInstaller(),
            currentVersion: AppVersion(string: "0.1.0-beta.3", build: 3)!
        )

        await controller.checkForUpdates(manual: false)
        #expect(controller.state == .idle)

        await controller.checkForUpdates(manual: true)
        if case .failed(let message) = controller.state {
            #expect(message == "离线")
        } else {
            Issue.record("Expected manual failure state")
        }
    }

    @Test func downloadVerifiesSHA256AndRejectsMismatch() async throws {
        let zipBytes = Data("fake-zip-archive".utf8)
        let validHash = SHA256.hash(data: zipBytes).map { String(format: "%02x", $0) }.joined()
        let payload = """
        [
          {
            "tag_name": "v0.1.0-beta.4-preview",
            "draft": false,
            "prerelease": true,
            "html_url": "https://github.com/isharechat/traylet/releases/tag/v0.1.0-beta.4-preview",
            "assets": [
              {
                "name": "Traylet-macos-arm64-v0.1.0-beta.4-build4.zip",
                "browser_download_url": "https://example.com/update.zip"
              },
              {
                "name": "Traylet-macos-arm64-v0.1.0-beta.4-build4.zip.sha256",
                "browser_download_url": "https://example.com/update.zip.sha256"
              }
            ]
          }
        ]
        """

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-update-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = PreferencesStore()
        let actions = SettingsActions(preferences: store, login: StubLogin())

        // Valid SHA-256 passes
        let goodTransport = MockUpdateTransport(
            feedData: Data(payload.utf8),
            sha256Text: "\(validHash)  Traylet-macos-arm64-v0.1.0-beta.4-build4.zip\n",
            zipData: zipBytes
        )
        let goodController = UpdateController(
            preferences: store,
            actions: actions,
            transport: goodTransport,
            installer: MockUpdateInstaller(canReplace: true),
            currentVersion: AppVersion(string: "0.1.0-beta.3", build: 3)!,
            currentBundleURL: { URL(fileURLWithPath: "/Applications/Traylet.app") },
            stagingRoot: tempDir
        )
        await goodController.checkForUpdates(manual: true)
        await goodController.downloadUpdate()
        if case .readyToInstall(let release, _, let canReplace) = goodController.state {
            #expect(release.tagName == "v0.1.0-beta.4-preview")
            #expect(canReplace == true)
        } else {
            Issue.record("Expected .readyToInstall on matching SHA-256")
        }

        // Mismatched SHA-256 fails
        let badHash = String(repeating: "0", count: 64)
        let badTransport = MockUpdateTransport(
            feedData: Data(payload.utf8),
            sha256Text: "\(badHash)  Traylet-macos-arm64-v0.1.0-beta.4-build4.zip\n",
            zipData: zipBytes
        )
        let badController = UpdateController(
            preferences: store,
            actions: actions,
            transport: badTransport,
            installer: MockUpdateInstaller(shouldRejectSHA: true),
            currentVersion: AppVersion(string: "0.1.0-beta.3", build: 3)!,
            stagingRoot: tempDir
        )
        await badController.checkForUpdates(manual: true)
        await badController.downloadUpdate()
        if case .failed = badController.state {
        } else {
            Issue.record("Expected .failed on SHA-256 mismatch")
        }
    }

    @Test func legacyPreferencesDecodeWithUpdateDefaults() throws {
        let legacyJSON = """
        {
          "schemaVersion": 2,
          "appearance": "dark",
          "language": "english",
          "glassEnabled": false,
          "hasCompletedWelcome": true
        }
        """
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: Data(legacyJSON.utf8))
        #expect(decoded.appearance == .dark)
        #expect(decoded.language == .english)
        #expect(decoded.glassEnabled == false)
        #expect(decoded.hasCompletedWelcome == true)
        #expect(decoded.autoCheckUpdates == true)
        #expect(decoded.includePreviewUpdates == true)
        #expect(decoded.skippedUpdateTag == nil)
    }

    @Test func fallsBackToAtomFeedWhenGitHubAPIReturns403() async {
        let atomXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <id>tag:github.com,2008:Repository/1/v0.1.0-beta.4-preview</id>
            <updated>2026-11-27T12:00:00Z</updated>
            <link rel="alternate" type="text/html" href="https://github.com/isharechat/traylet/releases/tag/v0.1.0-beta.4-preview"/>
            <title>Traylet v0.1.0-beta.4-preview</title>
            <content type="html">&lt;p&gt;Shamrock logo&lt;/p&gt;</content>
          </entry>
        </feed>
        """
        let assetsHTML = """
        <a href="/isharechat/traylet/releases/download/v0.1.0-beta.4-preview/Traylet-macos-arm64-v0.1.0-beta.4-build4.zip">zip</a>
        <a href="/isharechat/traylet/releases/download/v0.1.0-beta.4-preview/Traylet-macos-arm64-v0.1.0-beta.4-build4.zip.sha256">sha</a>
        """
        let transport = MockUpdateTransport(
            feedError: UpdateHTTPError.rateLimited(statusCode: 403),
            responsesByHostOrPath: [
                "releases.atom": Data(atomXML.utf8),
                "expanded_assets/v0.1.0-beta.4-preview": Data(assetsHTML.utf8),
            ]
        )
        let store = PreferencesStore()
        let actions = SettingsActions(preferences: store, login: StubLogin())
        let controller = UpdateController(
            preferences: store,
            actions: actions,
            transport: transport,
            installer: MockUpdateInstaller(),
            feedURL: UpdateController.defaultFeedURL,
            currentVersion: AppVersion(string: "0.1.0-beta.3", build: 3)!
        )

        await controller.checkForUpdates(manual: true)
        guard case .available(let release) = controller.state else {
            Issue.record("Expected .available state via Atom fallback, got \(controller.state)")
            return
        }
        #expect(release.tagName == "v0.1.0-beta.4-preview")
        #expect(release.version.build == 4)
        #expect(release.downloadURL?.absoluteString == "https://github.com/isharechat/traylet/releases/download/v0.1.0-beta.4-preview/Traylet-macos-arm64-v0.1.0-beta.4-build4.zip")
        #expect(release.sha256URL?.absoluteString == "https://github.com/isharechat/traylet/releases/download/v0.1.0-beta.4-preview/Traylet-macos-arm64-v0.1.0-beta.4-build4.zip.sha256")
        #expect(release.releaseNotes == "Shamrock logo")
    }
}

private final class MockUpdateTransport: UpdateTransport, @unchecked Sendable {
    let feedData: Data
    let feedError: Error?
    let sha256Text: String
    let zipData: Data
    let responsesByHostOrPath: [String: Data]

    init(
        feedData: Data = Data(),
        feedError: Error? = nil,
        sha256Text: String = "",
        zipData: Data = Data(),
        responsesByHostOrPath: [String: Data] = [:]
    ) {
        self.feedData = feedData
        self.feedError = feedError
        self.sha256Text = sha256Text
        self.zipData = zipData
        self.responsesByHostOrPath = responsesByHostOrPath
    }

    func fetchData(from url: URL) async throws -> Data {
        for (key, value) in responsesByHostOrPath where url.absoluteString.contains(key) {
            return value
        }
        if url.absoluteString.hasSuffix(".sha256") {
            return Data(sha256Text.utf8)
        }
        if let feedError { throw feedError }
        return feedData
    }

    func downloadFile(from url: URL, to destination: URL) async throws {
        try zipData.write(to: destination)
    }
}

private struct MockUpdateInstaller: UpdateInstalling {
    var canReplace = false
    var shouldRejectSHA = false

    func verifyAndUnpack(zipURL: URL, expectedSHA256: String, into stagingDirectory: URL) throws -> URL {
        if shouldRejectSHA {
            throw FeatureIssue.unavailable("更新包 SHA-256 校验失败，已中止安装。")
        }
        return stagingDirectory.appendingPathComponent("Traylet.app", isDirectory: true)
    }

    func canReplaceRunningApp(currentAppURL: URL?) -> Bool { canReplace }
    func installAndRelaunch(stagedAppURL: URL, targetAppURL: URL, currentPID: Int32) throws {}
    func revealInFinder(_ url: URL) {}
    func openURL(_ url: URL) {}
}

@MainActor private final class StubLogin: LoginItemManaging {
    var enabled = false
    var requiresApproval = false
    func setEnabled(_ value: Bool) throws {}
}
