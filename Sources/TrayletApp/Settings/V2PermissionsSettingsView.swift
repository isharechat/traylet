import AppKit
import SwiftUI

/// The "Permissions" settings pane: screen recording, accessibility and launch at login
/// in one place, with live status, request, jump and toggle actions.
struct V2PermissionsSettingsView: View {
    @ObservedObject var status: V2PermissionStatus
    @ObservedObject var actions: V2SettingsActions
    @ObservedObject private var localization = V2Localization.shared
    private var english: Bool { localization.english }
    private func text(_ chinese: String, _ englishText: String) -> String { english ? englishText : chinese }

    var body: some View {
        Form {
            Section {
                row(.screenRecording)
                Divider()
                row(.accessibility)
                Divider()
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
        V2LoginItemRow(
            symbol: V2PermissionKind.loginItem.symbol,
            title: V2PermissionKind.loginItem.title(english: english),
            detail: V2PermissionKind.loginItem.detail(english: english),
            enabled: actions.loginEnabled,
            requiresApproval: actions.loginRequiresApproval,
            setEnabled: { actions.setLoginEnabled($0) }
        )
    }

    private func row(_ kind: V2PermissionKind) -> some View {
        let granted = kind == .screenRecording ? status.screenRecordingGranted : status.accessibilityGranted
        return V2PermissionRow(symbol: kind.symbol, title: kind.title(english: english), detail: kind.detail(english: english), granted: granted) {
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
