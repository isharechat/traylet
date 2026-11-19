import AppKit
import Testing
@testable import TrayletApp

@MainActor private final class BoolBox {
    var value: Bool
    init(_ value: Bool = false) { self.value = value }
}

@Suite("Permission status") @MainActor struct PermissionStatusTests {
    @Test func readersDriveThePublishedStateAndRefreshPicksUpChanges() {
        let screen = BoolBox(false)
        let accessible = BoolBox(false)
        let status = V2PermissionStatus(
            readScreenRecording: { screen.value },
            readAccessibility: { accessible.value },
            requestScreenRecordingAction: { false },
            requestAccessibilityAction: { /* Not exercised in this test. */ },
            openScreenRecordingAction: { /* Not exercised in this test. */ },
            openAccessibilityAction: { /* Not exercised in this test. */ })
        #expect(!status.screenRecordingGranted)
        #expect(!status.accessibilityGranted)
        screen.value = true; accessible.value = true
        status.refresh()
        #expect(status.screenRecordingGranted)
        #expect(status.accessibilityGranted)
    }

    @Test func requestingScreenRecordingFallsBackToSettingsOnlyWhenDenied() {
        let requested = BoolBox(false)
        let opened = BoolBox(false)
        let screen = BoolBox(false)
        let status = V2PermissionStatus(
            readScreenRecording: { screen.value },
            readAccessibility: { false },
            requestScreenRecordingAction: { requested.value = true; return screen.value },
            requestAccessibilityAction: { /* Not exercised in this test. */ },
            openScreenRecordingAction: { opened.value = true },
            openAccessibilityAction: { /* Not exercised in this test. */ })
        status.requestScreenRecording()
        #expect(requested.value && opened.value && !status.screenRecordingGranted)
        requested.value = false; opened.value = false; screen.value = true
        status.requestScreenRecording()
        #expect(!requested.value && !opened.value && status.screenRecordingGranted)
    }

    @Test func requestingAccessibilityTriggersTheSystemPromptAndRefreshes() {
        let prompted = BoolBox(false)
        let accessible = BoolBox(false)
        let status = V2PermissionStatus(
            readScreenRecording: { false },
            readAccessibility: { accessible.value },
            requestScreenRecordingAction: { false },
            requestAccessibilityAction: { prompted.value = true },
            openScreenRecordingAction: { /* Not exercised in this test. */ },
            openAccessibilityAction: { /* Not exercised in this test. */ })
        status.requestAccessibility()
        #expect(prompted.value)
        accessible.value = true
        status.requestAccessibility()
        #expect(status.accessibilityGranted)
    }
}

@Suite("Permission section") @MainActor struct PermissionSectionTests {
    @Test func permissionsSitsBetweenClipboardAndAboutWithItsOwnCopy() {
        let cases = V2SettingsSection.allCases
        #expect(cases.firstIndex(of: .permissions) == cases.firstIndex(of: .about).map { $0 - 1 })
        #expect(cases.firstIndex(of: .permissions) == cases.firstIndex(of: .clipboard).map { $0 + 1 })
        #expect(V2SettingsSection.permissions.symbol == "lock.shield")
        #expect(V2SettingsSection.permissions.title(english: false) == "权限")
        #expect(V2SettingsSection.permissions.title(english: true) == "Permissions")
    }

    @Test func permissionKindCopyMatchesThePRDCopyTable() {
        #expect(V2PermissionKind.screenRecording.title(english: false) == "屏幕录制")
        #expect(V2PermissionKind.screenRecording.title(english: true) == "Screen Recording")
        #expect(V2PermissionKind.screenRecording.detail(english: false) == "截图功能需要（区域/整屏截图）")
        #expect(V2PermissionKind.screenRecording.detail(english: true) == "Required for captures (region / full screen)")
        #expect(V2PermissionKind.accessibility.title(english: false) == "辅助功能（可选）")
        #expect(V2PermissionKind.accessibility.title(english: true) == "Accessibility (optional)")
        #expect(V2PermissionKind.accessibility.detail(english: false) == "输入翻译时带入其他应用的选中文字")
        #expect(V2PermissionKind.accessibility.detail(english: true) == "Brings selected text from other apps into Input Translation")
        #expect(V2PermissionKind.loginItem.title(english: false) == "登录时启动")
        #expect(V2PermissionKind.loginItem.title(english: true) == "Launch at Login")
        #expect(V2PermissionKind.loginItem.detail(english: false) == "登录后在菜单栏自动打开 Traylet")
        #expect(V2PermissionKind.loginItem.detail(english: true) == "Open Traylet in the menu bar after login")
    }
}
