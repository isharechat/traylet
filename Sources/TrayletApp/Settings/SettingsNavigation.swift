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
        case .general: english ? "Language, appearance, and Liquid Glass preference" : "语言、外观与液态玻璃材质偏好"
        case .shortcuts: english ? "Global shortcuts and conflict resolution" : "全局唤醒快捷键录制与冲突恢复"
        case .ocr: english ? "Default engine, AI vision model, and prompts" : "默认引擎、AI 视觉模型与识别提示词"
        case .translation: english ? "Language packs, default engine, and external services" : "系统语言包、默认引擎与外部服务配置"
        case .clipboard: english ? "Local archive limits, types, and excluded apps" : "本机归档上限、记录类型与排除应用"
        case .permissions: english ? "Screen Recording, Accessibility, and Login Item" : "屏幕录制、辅助功能与登录项系统授权"
        case .about: english ? "Version details and system framework notices" : "版本信息与系统框架声明"
        }
    }
}

/// One pane is shown at a time; choosing a sidebar row switches the pane directly.
@MainActor final class SettingsNavigation: ObservableObject {
    @Published private(set) var current = SettingsSection.general
    func navigate(to section: SettingsSection) { current = section }
}
