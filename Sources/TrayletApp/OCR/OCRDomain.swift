import Foundation

enum OCREngineChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case vision, ai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .vision: "本机 Vision"
        case .ai: "AI OCR"
        }
    }
}

enum OCRAIPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case plainText, markdown, formula, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .plainText: "纯文本"
        case .markdown: "Markdown 表格"
        case .formula: "数学公式"
        case .custom: "自定义"
        }
    }
    var systemPrompt: String {
        switch self {
        case .plainText:
            return "Extract all text from the image accurately, preserving the original language and natural paragraphs. Return only the recognized text without extra commentary."
        case .markdown:
            return "Extract the content from the image and format it as clean Markdown, preserving headings, lists, and tables accurately. Return only the Markdown content."
        case .formula:
            return "Extract all text and mathematical formulas from the image accurately. Format inline math with $...$ and display formulas with $$...$$ in LaTeX. Return only the recognized content."
        case .custom:
            return Self.plainText.systemPrompt
        }
    }
}

enum OCRPhase: Equatable, Sendable {
    case idle
    case recognizing
    case ready
    case failed(String)
}

enum OCRTextPostProcessor {
    /// Joins single line breaks within paragraphs while keeping blank-line paragraph separators (`\n\n`).
    /// Adjacent CJK characters are joined directly; other boundaries insert a single space.
    static func mergeLineBreaks(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var paragraphs: [String] = []
        var current = ""

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = ""
                }
                continue
            }
            if current.isEmpty {
                current = line
            } else if shouldJoinWithoutSpace(left: current.last, right: line.first) {
                current += line
            } else {
                current += " " + line
            }
        }
        if !current.isEmpty {
            paragraphs.append(current)
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func shouldJoinWithoutSpace(left: Character?, right: Character?) -> Bool {
        guard let left, let right else { return false }
        return isCJKOrFullwidth(left) || isCJKOrFullwidth(right)
    }

    private static func isCJKOrFullwidth(_ char: Character) -> Bool {
        for scalar in char.unicodeScalars {
            switch scalar.value {
            case 0x3000...0x303F, // CJK Symbols and Punctuation
                 0x3040...0x309F, // Hiragana
                 0x30A0...0x30FF, // Katakana
                 0x3400...0x4DBF, // CJK Unified Ideographs Extension A
                 0x4E00...0x9FFF, // CJK Unified Ideographs
                 0xAC00...0xD7AF, // Hangul Syllables
                 0xF900...0xFAFF, // CJK Compatibility Ideographs
                 0xFF00...0xFFEF: // Halfwidth and Fullwidth Forms
                return true
            default:
                continue
            }
        }
        return false
    }
}
