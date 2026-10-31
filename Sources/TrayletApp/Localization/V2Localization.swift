import Foundation
import Combine

/// Localizes app-owned interface strings only. Unknown text is deliberately unchanged.
/// Never pass a user's input, OCR result, translation, clipboard content, model, or URL here.
@MainActor final class V2Localization: ObservableObject {
    static let shared = V2Localization()
    @Published var languageCode: String
    private let preferredLanguages: () -> [String]

    init(languageCode: String = "", preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.languageCode = languageCode
        self.preferredLanguages = preferredLanguages
    }

    var english: Bool {
        switch languageCode {
        case "en": return true
        case "zh-Hans": return false
        default: return Self.usesEnglish(preferredLanguages())
        }
    }

    func text(_ chinese: String) -> String {
        english ? (V2English.strings[chinese] ?? chinese) : chinese
    }

    /// Match supported app languages in the user's preference order; English is the fallback.
    static func usesEnglish(_ languages: [String]) -> Bool {
        for language in languages {
            let base = language.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first
            if base == "zh" { return false }
            if base == "en" { return true }
        }
        return true
    }
}

@MainActor func V2L(_ text: String) -> String { V2Localization.shared.text(text) }
