import AppKit
import SwiftUI

/// The "Permissions" settings pane: screen recording, accessibility and launch at login
/// in one place, with live status, request, jump and toggle actions.
struct PermissionsSettingsView: View {
    @ObservedObject var status: PermissionStatus
    @ObservedObject var actions: SettingsActions
    @ObservedObject private var localization = Localization.shared
    private var english: Bool { localization.english }
    private func text(_ chinese: String, _ englishText: String) -> String { english ? englishText : chinese }

    var body: some View {
        Form {
            Section {
                row(.screenRecording)
                row(.accessibility)
                loginRow
            } footer: {
                Text(text("授权变更后回到本页会自动刷新。",
                         "Permission changes refresh automatically when you return to this page."))
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            MainActor.assumeIsolated { actions.refreshLoginStatus() }
        }
    }

    private var loginRow: some View {
        LoginItemRow(
            symbol: PermissionKind.loginItem.symbol,
            title: PermissionKind.loginItem.title(english: english),
            detail: PermissionKind.loginItem.detail(english: english),
            enabled: actions.loginEnabled,
            requiresApproval: actions.loginRequiresApproval,
            setEnabled: { actions.setLoginEnabled($0) }
        )
    }

    private func row(_ kind: PermissionKind) -> some View {
        let granted = kind == .screenRecording ? status.screenRecordingGranted : status.accessibilityGranted
        return PermissionRow(symbol: kind.symbol, title: kind.title(english: english), detail: kind.detail(english: english), granted: granted, verticalPadding: 2) {
            if granted {
                Button(text("打开系统设置", "Open System Settings")) {
                    if kind == .screenRecording { status.openScreenRecordingSettings() } else { status.openAccessibilitySettings() }
                }.controlSize(.small)
            } else {
                Button(text("请求权限", "Request Permission")) {
                    if kind == .screenRecording { status.requestScreenRecording() } else { status.requestAccessibility() }
                }.buttonStyle(.borderedProminent).controlSize(.small)
                Button(text("打开系统设置", "Open System Settings")) {
                    if kind == .screenRecording { status.openScreenRecordingSettings() } else { status.openAccessibilitySettings() }
                }.controlSize(.small)
            }
        }
    }
}
