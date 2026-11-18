import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// The two TCC permissions Traylet exposes in its Permissions settings pane.
/// Login Items stay in General; this pane is only for the TCC class permissions.
enum V2PermissionKind: String, CaseIterable, Codable, Sendable {
    case screenRecording, accessibility

    var symbol: String {
        switch self {
        case .screenRecording: "record.circle"
        case .accessibility: "accessibility"
        }
    }

    func title(english: Bool) -> String {
        switch self {
        case .screenRecording: english ? "Screen Recording" : "屏幕录制"
        case .accessibility: english ? "Accessibility (optional)" : "辅助功能（可选）"
        }
    }

    /// Short usage line shared by the welcome window and the recovery prompt.
    func shortDetail(english: Bool) -> String {
        switch self {
        case .screenRecording: english ? "Required for captures" : "截图功能需要"
        case .accessibility: english ? "Brings selected text into Input Translation" : "输入翻译时带入选中文字"
        }
    }

    /// Full usage line for the Permissions settings pane.
    func detail(english: Bool) -> String {
        switch self {
        case .screenRecording: english ? "Required for captures (region / full screen)" : "截图功能需要（区域/整屏截图）"
        case .accessibility: english ? "Brings selected text from other apps into Input Translation" : "输入翻译时带入其他应用的选中文字"
        }
    }
}

/// Reads the current TCC state, requests the system prompts and opens the matching panes.
/// It refreshes on app activation so a return from System Settings is reflected immediately.
/// All decisions are read-only and go through the normal macOS authorization flow.
@MainActor final class V2PermissionStatus: ObservableObject {
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
        requestAccessibilityAction: @escaping @MainActor () -> Void = { V2AccessibilitySelectedText.requestTrust() },
        openScreenRecordingAction: @escaping @MainActor () -> Void = { V2PermissionStatus.openScreenRecordingSettings() },
        openAccessibilityAction: @escaping @MainActor () -> Void = { V2AccessibilitySelectedText.openSettings() },
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
struct V2PermissionRow<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: V2Design.Space.m) {
            Image(systemName: granted ? "checkmark.circle.fill" : symbol)
                .font(.system(size: 20))
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: V2Design.Space.s)
            Text(V2L(granted ? "已允许" : "未允许"))
                .font(.caption)
                .foregroundStyle(granted ? Color.secondary : Color.orange)
            actions()
        }
        .padding(.vertical, V2Design.Space.m)
    }
}
