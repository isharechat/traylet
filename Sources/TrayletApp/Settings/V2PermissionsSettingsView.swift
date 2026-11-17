import SwiftUI

/// The "Permissions" settings pane: two TCC rows with live status, request and jump actions.
struct V2PermissionsSettingsView: View {
    @ObservedObject var status: V2PermissionStatus
    @ObservedObject private var localization = V2Localization.shared
    private var english: Bool { localization.english }
    private func text(_ chinese: String, _ englishText: String) -> String { english ? englishText : chinese }

    var body: some View {
        Form {
            Section {
                row(.screenRecording)
                Divider()
                row(.accessibility)
            } footer: {
                Text(text("修改授权后回到本页会自动刷新状态，如仍无法读取请重新打开 Traylet。",
                         "This page refreshes when you return to it after changing the permission. If it still doesn't update, reopen Traylet."))
            }
        }
        .formStyle(.grouped)
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
