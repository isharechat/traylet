import AppKit
import Testing
@testable import TrayletApp

@Suite("Selected text safety") @MainActor struct SelectedTextSafetyTests {
    @Test(arguments: ["secureRole", "secureSubrole", "unknownFieldSubrole"])
    func protectedOrUnclassifiedFieldsNeverRequestTheSelection(_ scenario: String) {
        let element = FakeSelectedTextFocus()
        switch scenario {
        case "secureRole": element.role = .value("AXSecureTextField")
        case "secureSubrole": element.subrole = .value("AXSecureTextField")
        default: element.subrole = .unsupported
        }
        let reader = AccessibilitySelectedText(focus: { element.snapshot })
        #expect(reader.selectedText() == nil)
        #expect(element.selectionReads == 0)
    }
    @Test(arguments: ["AXTextField", "AXTextArea", "AXStaticText"])
    func normalSelectionsRemainAvailableAndTrimmed(_ role: String) {
        let element = FakeSelectedTextFocus()
        element.role = .value(role)
        if role == "AXTextArea" { element.subrole = .unsupported }
        let reader = AccessibilitySelectedText(focus: { element.snapshot })
        #expect(reader.selectedText() == "Synthetic selection")
        #expect(element.selectionReads == 1)
    }
    @Test(arguments: ["beforeRead", "afterClassification", "afterSelection", "afterFinalClassification", "becameSecure"])
    func lossOrChangeOfFocusDiscardsTheSelection(_ moment: String) {
        let element = FakeSelectedTextFocus()
        defer { element.onRead = nil }
        var classifications = 0
        if moment == "beforeRead" { element.current = false }
        element.onRead = { attribute in
            if attribute == .subrole { classifications += 1 }
            if moment == "afterClassification", attribute == .subrole { element.current = false }
            if moment == "afterFinalClassification", classifications == 2 { element.current = false }
            if moment == "afterSelection", attribute == .selection { element.current = false }
            if moment == "becameSecure", attribute == .selection { element.subrole = .value("AXSecureTextField") }
        }
        let reader = AccessibilitySelectedText(focus: { element.snapshot })
        #expect(reader.selectedText() == nil)
        #expect(element.selectionReads == (moment == "beforeRead" || moment == "afterClassification" ? 0 : 1))
    }
    @Test(arguments: ["roleFailed", "roleUnsupported", "roleEmpty", "roleMalformed", "subroleFailed", "subroleEmpty", "secureCase"])
    func metadataFailuresDoNotRequestContent(_ problem: String) {
        let element = FakeSelectedTextFocus()
        switch problem {
        case "roleFailed": element.role = .unavailable
        case "roleUnsupported": element.role = .unsupported
        case "roleEmpty": element.role = .value("")
        case "roleMalformed": element.role = .value(" AXSecureTextField ")
        case "subroleFailed": element.subrole = .unavailable
        case "subroleEmpty": element.subrole = .value("")
        default: element.subrole = .value("axsecuretextfield")
        }
        #expect(AccessibilitySelectedText(focus: { element.snapshot }).selectedText() == nil)
        #expect(element.selectionReads == 0)
    }
    @Test(arguments: ["unsupported", "failed", "empty"])
    func unavailableOrEmptySelectionsHaveNoFallback(_ result: String) {
        let element = FakeSelectedTextFocus()
        switch result {
        case "unsupported": element.selection = .unsupported
        case "failed": element.selection = .unavailable
        default: element.selection = .value(" \n\t ")
        }
        #expect(AccessibilitySelectedText(focus: { element.snapshot }).selectedText() == nil)
        #expect(element.selectionReads == 1)
    }
    @Test func readerKeepsTheExistingUnicodeSelectionLimit() {
        let element = FakeSelectedTextFocus()
        element.selection = .value("  " + String(repeating: "😀", count: 20_001) + "\n")
        let result = AccessibilitySelectedText(focus: { element.snapshot }).selectedText()
        #expect(result?.count == 20_000)
        #expect(result?.first == "😀" && result?.last == "😀")
    }
    @Test func constructionIsLazyAndAWithdrawnFocusDoesNotReuseAPreviousSelection() {
        let element = FakeSelectedTextFocus()
        var available = true, acquisitions = 0
        let reader = AccessibilitySelectedText(focus: { acquisitions += 1; return available ? element.snapshot : nil })
        #expect(acquisitions == 0 && element.selectionReads == 0)
        #expect(reader.selectedText() == "Synthetic selection")
        available = false
        #expect(reader.selectedText() == nil && element.selectionReads == 1)
        available = true
        element.selection = .value("Current synthetic selection")
        #expect(reader.selectedText() == "Current synthetic selection")
    }
    @Test func parameterizedSelectionFallbackReadsOnlyTheSelectedRange() {
        let element = FakeSelectedTextFocus()
        element.role = .value("AXTextArea")
        element.subrole = .unsupported
        element.selection = .unsupported
        element.parameterizedSelection = .value("Range-only selection")
        let reader = AccessibilitySelectedText(focus: { element.snapshot })
        #expect(reader.selectedText() == "Range-only selection")
        #expect(element.selectionReads == 1)
        #expect(element.parameterizedReads == 1)
    }
    @Test(arguments: ["plain", "attributed", "unsupportedValue"])
    func selectionValuesAreReducedToPlainText(_ scenario: String) {
        let value: Any?
        let expected: String?
        switch scenario {
        case "plain": value = "Plain selection"; expected = "Plain selection"
        case "attributed": value = NSAttributedString(string: "Attributed selection"); expected = "Attributed selection"
        default: value = NSNumber(value: 42); expected = nil
        }
        #expect(AccessibilitySelectedText.text(from: value) == expected)
    }
}

@MainActor private final class FakeSelectedTextFocus {
    var role = SelectedTextAttributeResult.value("AXTextField")
    var subrole = SelectedTextAttributeResult.value("AXUnknown")
    var selection = SelectedTextAttributeResult.value("  Synthetic selection \n")
    var parameterizedSelection: SelectedTextAttributeResult?
    var selectionReads = 0
    var parameterizedReads = 0
    var current = true
    var onRead: ((SelectedTextAttribute) -> Void)?
    var snapshot: SelectedTextFocus {
        let readAttribute: @MainActor (SelectedTextAttribute) -> SelectedTextAttributeResult = { [self] attribute in
            let result: SelectedTextAttributeResult
            switch attribute {
            case .role: result = role
            case .subrole: result = subrole
            case .selection: selectionReads += 1; result = selection
            }
            onRead?(attribute)
            return result
        }
        let readSelectedText: @MainActor () -> SelectedTextAttributeResult = { [self] in
            if case .value(let text) = readAttribute(.selection), !text.isEmpty { return .value(text) }
            guard let parameterizedSelection else { return .unsupported }
            parameterizedReads += 1
            return parameterizedSelection
        }
        return SelectedTextFocus(
            attribute: readAttribute,
            selectedText: readSelectedText,
            isCurrent: { [self] in current }
        )
    }
}
