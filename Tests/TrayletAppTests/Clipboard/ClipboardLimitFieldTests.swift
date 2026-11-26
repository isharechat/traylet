import Testing
@testable import TrayletApp

struct ClipboardLimitFieldTests {
    @Test func manualLimitsAcceptWholeValuesWithinExistingBounds() {
        for value in [1, 37, 100, 999, 1000] {
            #expect(ClipboardLimitField.parse(String(value), in: 1...1000) == value)
        }
        #expect(ClipboardLimitField.parse(" 14 ", in: 1...30) == 14)
        #expect(ClipboardLimitField.parse("30", in: 1...30) == 30)
    }
    @Test func incompleteInvalidAndOutOfRangeEditsCannotCommitDestructiveLimits() {
        for draft in ["", " ", "-", "0", "-1", "1.5", "1e2", "12x", "1001", "99999999999999999999999"] {
            #expect(ClipboardLimitField.parse(draft, in: 1...1000) == nil)
        }
        #expect(ClipboardLimitField.parse("31", in: 1...30) == nil)
    }
}
