import Foundation
import Combine
import ServiceManagement

@MainActor protocol V2LoginItemManaging: AnyObject {
    var enabled: Bool { get }
    var requiresApproval: Bool { get }
    func setEnabled(_ value: Bool) throws
}

/// Registration is performed only by setEnabled, after an explicit toggle action.
@MainActor final class V2SystemLoginItem: V2LoginItemManaging {
    var enabled: Bool { SMAppService.mainApp.status == .enabled }
    var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
    func setEnabled(_ value: Bool) throws {
        if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

@MainActor final class V2SettingsActions: ObservableObject {
    @Published private(set) var loginEnabled: Bool
    @Published private(set) var loginRequiresApproval: Bool
    @Published private(set) var issue: String?
    private let preferences: V2PreferencesStore
    private let login: any V2LoginItemManaging
    init(preferences: V2PreferencesStore, login: any V2LoginItemManaging = V2SystemLoginItem()) {
        self.preferences = preferences; self.login = login
        loginEnabled = login.enabled || login.requiresApproval; loginRequiresApproval = login.requiresApproval
    }
    func refreshLoginStatus() { loginEnabled = login.enabled || login.requiresApproval; loginRequiresApproval = login.requiresApproval }
    func setAppearance(_ value: V2Appearance) { save { $0.appearance = value } }
    func setLanguage(_ value: V2Language) { save { $0.language = value } }
    func setGlass(_ value: Bool) { save { $0.glassEnabled = value } }
    /// Called only by the explicit confirmation action in settings.
    func recoverPreferences(shortcuts: V2ShortcutManager) {
        do { try preferences.resetPreservingDamagedFile() }
        catch { issue = V2L("恢复失败，原偏好文件已保留。请检查新版本偏好文件的路径与权限。"); return }
        do { try shortcuts.start(); issue = nil }
        catch { issue = V2L("默认偏好已恢复，但快捷键注册失败。可继续使用菜单，并在快捷键分区选择其他组合重试。") }
    }
    func setLoginEnabled(_ value: Bool) {
        do { try login.setEnabled(value); issue = nil } catch { issue = V2L("登录项未更改。请确认从 Applications 中启动 Traylet，并在系统设置中检查登录项。") }
        refreshLoginStatus()
    }
    private func save(_ change: (inout V2UserPreferences) -> Void) {
        var value = preferences.value; change(&value)
        do { try preferences.save(value); issue = nil } catch { issue = V2L("设置未保存，原值已保留。请检查新版本偏好文件。") }
    }
}
