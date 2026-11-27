import Foundation
import Combine
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, shortcuts, ocr, translation, clipboard, permissions, about
    var id: String { rawValue }
    var symbol: String {
        switch self { case .general: "gearshape"; case .shortcuts: "keyboard"; case .ocr: "text.viewfinder"; case .translation: "character.bubble"; case .clipboard: "doc.on.clipboard"; case .permissions: "lock.shield"; case .about: "info.circle" }
    }
    /// Sidebar icon tile colour, as in System Settings.
    var tint: Color {
        switch self { case .general: .gray; case .shortcuts: .blue; case .ocr: .purple; case .translation: .green; case .clipboard: .orange; case .permissions: .teal; case .about: .indigo }
    }
    func title(english: Bool) -> String {
        switch self {
        case .general: english ? "General" : "通用"
        case .shortcuts: english ? "Shortcuts" : "快捷键"
        case .ocr: "OCR"
        case .translation: english ? "Translation" : "翻译"
        case .clipboard: english ? "Clipboard" : "剪贴板"
        case .permissions: english ? "Permissions" : "权限"
        case .about: english ? "About" : "关于"
        }
    }
    func subtitle(english: Bool) -> String {
        switch self {
        case .general: english ? "Language, appearance, and window surface" : "语言、外观与窗口材质"
        case .shortcuts: english ? "Global keyboard shortcuts for quick capture and tools" : "全局快捷键与触发组合"
        case .ocr: english ? "Local Vision and AI text recognition" : "本机文本识别与 AI 模式配置"
        case .translation: english ? "Default engine, credentials, and offline language packs" : "翻译引擎、凭据与离线语言包"
        case .clipboard: english ? "History retention, capture types, and excluded apps" : "历史容量、记录类型与排除应用"
        case .permissions: english ? "Screen recording, accessibility, and launch at login" : "屏幕录制、辅助功能与开机启动"
        case .about: english ? "Version details, updates, and notices" : "版本信息、软件更新与声明"
        }
    }
}

enum SettingsSectionGroup: CaseIterable, Identifiable {
    case basics, features, system
    var id: Self { self }
    var sections: [SettingsSection] {
        switch self {
        case .basics: [.general, .shortcuts]
        case .features: [.ocr, .translation, .clipboard]
        case .system: [.permissions, .about]
        }
    }
    func title(english: Bool) -> String {
        switch self {
        case .basics: english ? "Basics" : "基础"
        case .features: english ? "Features" : "功能"
        case .system: english ? "System" : "系统"
        }
    }
}

/// One pane is shown at a time; choosing a sidebar row switches the pane directly.
@MainActor final class SettingsNavigation: ObservableObject {
    @Published private(set) var current = SettingsSection.general
    func navigate(to section: SettingsSection) { current = section }
}
