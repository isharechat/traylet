import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// The system authorizations Traylet exposes in its Permissions settings pane.
/// Screen Recording and Accessibility are TCC class permissions; the Login Item row is the
/// SMAppService registration, grouped here so every system grant is managed in one place.
enum PermissionKind: String, CaseIterable, Codable, Sendable {
    case screenRecording, accessibility, loginItem

    var symbol: String {
        switch self {
        case .screenRecording: "record.circle"
        case .accessibility: "accessibility"
        case .loginItem: "power"
        }
    }

    func title(english: Bool) -> String {
        switch self {
        case .screenRecording: english ? "Screen Recording" : "屏幕录制"
        case .accessibility: english ? "Accessibility (optional)" : "辅助功能（可选）"
        case .loginItem: english ? "Launch at Login" : "登录时启动"
        }
    }

    /// Short usage line shared by the welcome window and the recovery prompt.
    func shortDetail(english: Bool) -> String {
        switch self {
        case .screenRecording: english ? "Required for captures" : "截图功能需要"
        case .accessibility: english ? "Brings selected text into Input Translation" : "输入翻译时带入选中文字"
        case .loginItem: english ? "Open Traylet in the menu bar after login" : "登录后在菜单栏自动打开 Traylet"
        }
    }

    /// Full usage line for the Permissions settings pane.
    func detail(english: Bool) -> String {
        switch self {
        case .screenRecording: english ? "Required for captures (region / full screen)" : "截图功能需要（区域/整屏截图）"
        case .accessibility: english ? "Brings selected text from other apps into Input Translation" : "输入翻译时带入其他应用的选中文字"
        case .loginItem: english ? "Open Traylet in the menu bar after login" : "登录后在菜单栏自动打开 Traylet"
        }
    }
}

/// Reads the current TCC state, requests the system prompts and opens the matching panes.
/// It refreshes on app activation so a return from System Settings is reflected immediately.
/// All decisions are read-only and go through the normal macOS authorization flow.
@MainActor final class PermissionStatus: ObservableObject {
    @Published private(set) var screenRecordingGranted: Bool
    @Published private(set) var accessibilityGranted: Bool

    private let readScreenRecording: @MainActor () -> Bool
    private let readAccessibility: @MainActor () -> Bool
    private let requestScreenRecordingAction: @MainActor () -> Bool
    private let requestAccessibilityAction: @MainActor () -> Void
    private let openScreenRecordingAction: @MainActor () -> Void
    private let openAccessibilityAction: @MainActor () -> Void
    private var observations: Set<AnyCancellable> = []

    init(
        readScreenRecording: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
        readAccessibility: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
        requestScreenRecordingAction: @escaping @MainActor () -> Bool = { CGRequestScreenCaptureAccess() },
        requestAccessibilityAction: @escaping @MainActor () -> Void = { AccessibilitySelectedText.requestTrust() },
        openScreenRecordingAction: @escaping @MainActor () -> Void = { PermissionStatus.openScreenRecordingSettings() },
        openAccessibilityAction: @escaping @MainActor () -> Void = { AccessibilitySelectedText.openSettings() },
        notificationCenter: NotificationCenter = .default
    ) {
        self.readScreenRecording = readScreenRecording
        self.readAccessibility = readAccessibility
        self.requestScreenRecordingAction = requestScreenRecordingAction
        self.requestAccessibilityAction = requestAccessibilityAction
        self.openScreenRecordingAction = openScreenRecordingAction
        self.openAccessibilityAction = openAccessibilityAction
        self.screenRecordingGranted = readScreenRecording()
        self.accessibilityGranted = readAccessibility()
        notificationCenter.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &observations)
    }

    func refresh() {
        screenRecordingGranted = readScreenRecording()
        accessibilityGranted = readAccessibility()
    }

    func requestScreenRecording() {
        if !readScreenRecording(), !requestScreenRecordingAction() {
            openScreenRecordingAction()
        }
        refresh()
    }

    func requestAccessibility() {
        requestAccessibilityAction()
        refresh()
    }

    func openScreenRecordingSettings() {
        openScreenRecordingAction()
    }

    func openAccessibilitySettings() {
        openAccessibilityAction()
    }

    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Shared permission row: icon, title, usage, an "allowed / not allowed" badge and caller-provided actions.
/// Used by the welcome window, the Permissions settings pane and the recovery prompt.
struct PermissionRow<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: Design.Space.m) {
            Image(systemName: granted ? "checkmark.circle.fill" : symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(granted ? Color.green : Color.accentColor)
                .frame(width: 30, height: 30)
                .background((granted ? Color.green : Color.accentColor).opacity(0.14),
                            in: RoundedRectangle(cornerRadius: Design.Radius.control))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Design.Space.s)
            StatusPill(
                text: L(granted ? "已允许" : "未允许"),
                tint: granted ? .green : .orange
            )
            actions()
        }
        .padding(.vertical, Design.Space.m)
    }
}

/// Login-item row for the Permissions pane. It shares the icon/title/detail lead of
/// `PermissionRow` but ends in a toggle instead of a status badge, because launch at
/// login is an on/off registration rather than a TCC grant.
struct LoginItemRow: View {
    let symbol: String
    let title: String
    let detail: String
    let enabled: Bool
    let requiresApproval: Bool
    let setEnabled: (Bool) -> Void

    var body: some View {
        HStack(spacing: Design.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                .frame(width: 30, height: 30)
                .background((enabled ? Color.accentColor : Color.secondary).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: Design.Radius.control))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if requiresApproval {
                    Text(L("需在系统设置 → 通用 → 登录项中批准"))
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: Design.Space.s)
            Toggle(title, isOn: Binding(get: { enabled }, set: setEnabled))
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, Design.Space.m)
    }
}
