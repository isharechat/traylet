import AppKit
import Testing
@testable import TrayletApp

@Suite("Selected text strategies") @MainActor struct SelectedTextStrategyTests {
    // MARK: Accessibility TextMarker fallback

    @Test func textMarkerFallbackRunsAfterPlainRangeFails() {
        let result = V2AccessibilitySelectedText.selectedTextFallback(
            selection: { .unsupported },
            selectedRange: { nil },
            stringForRange: { _ in .value("plain range") },
            selectedTextMarkerRange: { NSString(string: "marker") },
            stringForTextMarkerRange: { _ in .value("marker text") }
        )
        guard case .value(let text) = result else {
            Issue.record("expected marker text")
            return
        }
        #expect(text == "marker text")
    }

    @Test func plainSelectionWinsOverRangeAndMarker() {
        var rangeReads = 0, markerReads = 0
        let result = V2AccessibilitySelectedText.selectedTextFallback(
            selection: { .value("selected") },
            selectedRange: { rangeReads += 1; return CFRange(location: 0, length: 1) },
            stringForRange: { _ in .value("range") },
            selectedTextMarkerRange: { markerReads += 1; return NSString(string: "marker") },
            stringForTextMarkerRange: { _ in .value("marker") }
        )
        guard case .value(let text) = result else {
            Issue.record("expected selected text")
            return
        }
        #expect(text == "selected")
        #expect(rangeReads == 0 && markerReads == 0)
    }

    @Test func plainRangeWinsOverTextMarker() {
        var markerReads = 0
        let result = V2AccessibilitySelectedText.selectedTextFallback(
            selection: { .unsupported },
            selectedRange: { CFRange(location: 0, length: 1) },
            stringForRange: { _ in .value("range") },
            selectedTextMarkerRange: { markerReads += 1; return NSString(string: "marker") },
            stringForTextMarkerRange: { _ in .value("marker") }
        )
        guard case .value(let text) = result else {
            Issue.record("expected range text")
            return
        }
        #expect(text == "range")
        #expect(markerReads == 0)
    }

    // MARK: Strategy chain ordering and normalization

    @Test func chainReturnsFirstNonEmptyNormalizedResult() {
        let first = StubReader("  first  ")
        let second = StubReader("second")
        let chain = V2SelectedTextStrategyChain(strategies: [first, second])
        #expect(chain.selectedText() == "first")
        #expect(first.calls == 1 && second.calls == 0)
    }

    @Test func chainFallsThroughNilAndWhitespaceReaders() {
        let first = StubReader(nil)
        let whitespace = StubReader(" \n ")
        let third = StubReader("third")
        let chain = V2SelectedTextStrategyChain(strategies: [first, whitespace, third])
        #expect(chain.selectedText() == "third")
        #expect(first.calls == 1 && whitespace.calls == 1 && third.calls == 1)
    }

    // MARK: AppleScript mapping

    @Test func appleScriptMapsOnlySupportedBrowsers() {
        #expect(V2AppleScriptSelectedText.script(bundleIdentifier: "com.apple.Safari") != nil)
        #expect(V2AppleScriptSelectedText.script(bundleIdentifier: "com.google.Chrome") != nil)
        #expect(V2AppleScriptSelectedText.script(bundleIdentifier: "com.microsoft.edgemac") != nil)
        #expect(V2AppleScriptSelectedText.script(bundleIdentifier: "com.microsoft.Edge") != nil)
        #expect(V2AppleScriptSelectedText.script(bundleIdentifier: "com.example.other") == nil)
    }

    @Test func appleScriptReaderRunsMappedScriptForFrontmostBrowser() {
        let reader = V2AppleScriptSelectedText(frontmostBundleIdentifier: { "com.google.Chrome" },
                                               frontmostProcessIdentifier: { 42 },
                                               run: { source in
            #expect(source.contains("window.getSelection().toString()"))
            return "  scripted selection \n"
        })
        #expect(reader.selectedText() == "  scripted selection \n")
    }

    // MARK: Clipboard copy capture

    @Test func clipboardCaptureReadsCopyAndRestoresOriginal() throws {
        let board = try makeBoard("original")
        var ignoreMarks = 0
        let capture = V2ClipboardCopyCapture(pasteboard: { board }, markIgnoreNextCopy: { ignoreMarks += 1 },
                                             pollInterval: 0.01, timeout: 0.2)
        let result = capture.capture {
            write("copied selection", to: board)
        }
        #expect(result == "copied selection")
        #expect(board.string(forType: .string) == "original")
        #expect(ignoreMarks == 2)
    }

    @Test func clipboardRestoreSkipsWhenGenerationChanged() throws {
        let board = try makeBoard("original")
        let backup = try #require(V2ClipboardCopySupport.snapshotItems(board.pasteboardItems))
        write("copied", to: board)
        let observed = board.changeCount
        write("concurrent", to: board)
        #expect(!V2ClipboardCopySupport.restore(backup, on: board, observedGeneration: observed))
        #expect(board.string(forType: .string) == "concurrent")
    }

    @Test func clipboardRestoreAppliesWhenGenerationIsUnchanged() throws {
        let board = try makeBoard("original")
        let backup = try #require(V2ClipboardCopySupport.snapshotItems(board.pasteboardItems))
        write("copied", to: board)
        let observed = board.changeCount
        #expect(V2ClipboardCopySupport.restore(backup, on: board, observedGeneration: observed))
        #expect(board.string(forType: .string) == "original")
    }

    @Test func simulatedCopyReaderUsesInjectedCopyAndRestores() throws {
        let board = try makeBoard("original")
        let capture = V2ClipboardCopyCapture(pasteboard: { board }, pollInterval: 0.01, timeout: 0.2)
        let reader = V2SimulatedCopySelectedText(capture: capture, postCopy: {
            write("simulated copy", to: board)
        }, frontmostProcessIdentifier: { 12345 })
        #expect(reader.selectedText() == "simulated copy")
        #expect(board.string(forType: .string) == "original")
    }

    @Test func disabledMenuCopyDoesNotTouchClipboard() throws {
        let board = try makeBoard("original")
        var pressed = false
        let action = V2MenuActionSelectedText.CopyAction(enabled: false, press: { pressed = true })
        let capture = V2ClipboardCopyCapture(pasteboard: { board }, pollInterval: 0.01, timeout: 0.2)
        let reader = V2MenuActionSelectedText(resolveCopy: { action }, capture: capture)
        #expect(reader.selectedText() == nil)
        #expect(!pressed)
        #expect(board.string(forType: .string) == "original")
    }

    @Test func enabledMenuCopyPressesAndReadsClipboard() throws {
        let board = try makeBoard("original")
        var pressed = false
        let action = V2MenuActionSelectedText.CopyAction(enabled: true, press: {
            pressed = true
            write("menu copy", to: board)
        })
        let capture = V2ClipboardCopyCapture(pasteboard: { board }, pollInterval: 0.01, timeout: 0.2)
        let reader = V2MenuActionSelectedText(resolveCopy: { action }, capture: capture)
        #expect(reader.selectedText() == "menu copy")
        #expect(pressed)
        #expect(board.string(forType: .string) == "original")
    }

    // MARK: Helpers

    private func makeBoard(_ text: String) throws -> NSPasteboard {
        let board = NSPasteboard(name: .init("local.traylet.strategy.\(UUID().uuidString)"))
        board.clearContents()
        write(text, to: board)
        return board
    }

    private func write(_ text: String, to board: NSPasteboard) {
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        _ = board.writeObjects([item])
    }
}

@MainActor private final class StubReader: V2SelectedTextReading {
    let result: String?
    var calls = 0
    var isAuthorized: Bool { true }
    init(_ result: String?) { self.result = result }
    func selectedText() -> String? { calls += 1; return result }
}
