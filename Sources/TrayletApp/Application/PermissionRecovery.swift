import Combine
import SwiftUI

/// The two live permission booleans, separate from the persisted snapshot record.
struct PermissionState: Equatable, Sendable {
    var screenRecordingGranted: Bool
    var accessibilityGranted: Bool
}

/// Which permissions were granted before and are now missing (e.g. after an upgrade re-signs the app).
struct PermissionLoss: Equatable, Sendable {
    var screenRecording = false
    var accessibility = false
    var isEmpty: Bool { !screenRecording && !accessibility }

    /// A permission is only "lost" when the snapshot recorded it as granted and the live state is now not granted.
    /// A missing or damaged snapshot never reports a loss, so fresh users are not prompted.
    static func detecting(previous: PermissionSnapshot?, current: PermissionState) -> PermissionLoss {
        guard let previous else { return PermissionLoss() }
        return PermissionLoss(
            screenRecording: previous.lastScreenRecordingGranted && !current.screenRecordingGranted,
            accessibility: previous.lastAccessibilityGranted && !current.accessibilityGranted)
    }
}

/// Coordinates the one-time "permissions were lost" prompt after an upgrade.
/// It compares the persisted snapshot with the live state at launch, shows the prompt once,
/// and keeps the snapshot current so the next genuine loss is detected again.
@MainActor final class PermissionRecovery {
    private let snapshotStore: PermissionSnapshotStore
    private let status: PermissionStatus
    private let present: @MainActor (PermissionLoss) -> Void
    private var observations: Set<AnyCancellable> = []
    private var lastPersisted: PermissionSnapshot?
    private var tracking = false
    private var presentedThisRun = false

    init(snapshotStore: PermissionSnapshotStore, status: PermissionStatus,
         present: @escaping @MainActor (PermissionLoss) -> Void) {
        self.snapshotStore = snapshotStore
        self.status = status
        self.present = present
    }

    /// Returns true when the one-time recovery prompt was shown.
    func runStartupCheck(hasCompletedWelcome: Bool) -> Bool {
        let previous = snapshotStore.load()
        let current = PermissionState(screenRecordingGranted: status.screenRecordingGranted,
                                        accessibilityGranted: status.accessibilityGranted)
        let losses = PermissionLoss.detecting(previous: previous, current: current)
        // Advance the snapshot now so the consumed "was granted" marker is never replayed this run.
        persist(current)
        beginTracking()
        guard hasCompletedWelcome, !losses.isEmpty, !presentedThisRun else { return false }
        presentedThisRun = true
        present(losses)
        return true
    }

    /// Keeps the snapshot current after startup so a grant made later (in Settings or the prompt)
    /// is recorded and a future loss can be detected.
    private func beginTracking() {
        guard !tracking else { return }
        tracking = true
        Publishers.CombineLatest(status.$screenRecordingGranted, status.$accessibilityGranted)
            .sink { [weak self] screenRecording, accessibility in
                MainActor.assumeIsolated {
                    self?.persist(PermissionState(screenRecordingGranted: screenRecording, accessibilityGranted: accessibility))
                }
            }
            .store(in: &observations)
    }

    private func persist(_ state: PermissionState) {
        var snapshot = PermissionSnapshot()
        snapshot.lastScreenRecordingGranted = state.screenRecordingGranted
        snapshot.lastAccessibilityGranted = state.accessibilityGranted
        guard snapshot != lastPersisted else { return }
        do { try snapshotStore.save(snapshot); lastPersisted = snapshot } catch { /* Best effort; a failed snapshot never blocks the app. */ }
    }
}

/// The lightweight one-time recovery prompt; only the actually lost permissions are listed.
/// It closes via "Later", or automatically once every listed permission is granted again.
struct PermissionRecoveryView: View {
    @ObservedObject var status: PermissionStatus
    let losses: PermissionLoss
    let english: Bool
    let onLater: () -> Void

    private var allGranted: Bool {
        (!losses.screenRecording || status.screenRecordingGranted)
            && (!losses.accessibility || status.accessibilityGranted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.l) {
            HStack(spacing: Design.Space.m) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.teal.gradient, in: RoundedRectangle(cornerRadius: Design.Radius.control + 2))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(english ? "Permissions need to be re-granted" : "权限需要重新授权")
                        .font(.headline)
                    Text(english ? "After the update, Traylet needs you to allow the following permissions again."
                                 : "升级后，Traylet 需要你重新允许以下系统权限。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            SettingsGroup {
                if losses.screenRecording {
                    row(.screenRecording)
                }
                if losses.screenRecording && losses.accessibility {
                    Divider()
                }
                if losses.accessibility {
                    row(.accessibility)
                }
            }
            HStack {
                Spacer()
                Button(english ? "Later" : "稍后", action: onLater)
            }
        }
        .padding(Design.Space.xl)
        .frame(width: 460)
        .onChange(of: status.screenRecordingGranted) { _, _ in if allGranted { onLater() } }
        .onChange(of: status.accessibilityGranted) { _, _ in if allGranted { onLater() } }
    }

    private func row(_ kind: PermissionKind) -> some View {
        let granted = kind == .screenRecording ? status.screenRecordingGranted : status.accessibilityGranted
        return PermissionRow(symbol: kind.symbol, title: kind.title(english: english), detail: kind.shortDetail(english: english), granted: granted) {
            if !granted {
                Button(english ? "Allow…" : "允许…") {
                    if kind == .screenRecording { status.requestScreenRecording() } else { status.requestAccessibility() }
                }.buttonStyle(.borderedProminent)
            }
        }
    }
}
