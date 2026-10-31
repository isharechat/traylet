import Foundation
import Combine
import SwiftUI

enum V2SettingsSection: String, CaseIterable, Identifiable {
    case general, shortcuts, translation, clipboard, about
    var id: String { rawValue }
    var symbol: String {
        switch self { case .general: "gearshape"; case .shortcuts: "keyboard"; case .translation: "character.bubble"; case .clipboard: "doc.on.clipboard"; case .about: "info.circle" }
    }
    /// Sidebar icon tile colour, as in System Settings.
    var tint: Color {
        switch self { case .general: .gray; case .shortcuts: .blue; case .translation: .green; case .clipboard: .orange; case .about: .indigo }
    }
    func title(english: Bool) -> String {
        switch self {
        case .general: english ? "General" : "通用"
        case .shortcuts: english ? "Shortcuts" : "快捷键"
        case .translation: english ? "Translation" : "翻译"
        case .clipboard: english ? "Clipboard" : "剪贴板"
        case .about: english ? "About" : "关于"
        }
    }
}

/// One pane is shown at a time; choosing a sidebar row switches the pane directly.
@MainActor final class V2SettingsNavigation: ObservableObject {
    @Published private(set) var current = V2SettingsSection.general
    func navigate(to section: V2SettingsSection) { current = section }
}
