import AppKit
import Testing
@testable import TrayletApp

@Suite("Clipboard Keyboard") @MainActor struct ClipboardKeyboardTests {
    @Test func everyPresentationFocusesSearchWithoutResettingQuery() async throws {
        let fixture = ClipboardKeyboardFixture()
        defer { fixture.feature.shutdown(); try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.feature.controller.query = "preserved query"
        fixture.feature.present()
        try await Task.sleep(for: .milliseconds(80))
        let panel = try #require(fixture.presentation.panel)
        let field = try #require(searchField(in: panel.contentView))
        #expect(!panel.isVisible)
        #expect(field.currentEditor() === panel.firstResponder)
        panel.makeFirstResponder(nil)
        fixture.feature.present()
        #expect(field.currentEditor() === panel.firstResponder)
        #expect(field.stringValue == "preserved query")
        #expect(!fixture.feature.controller.enabled && fixture.source.reads == 0)
        await fixture.feature.shutdownAndWait()
    }
    @Test func nativeSearchKeysMoveOnlyVisibleResultsAndCloseOnlyAfterSuccessfulCopy() async throws {
        let fixture = ClipboardKeyboardFixture()
        defer { fixture.feature.shutdown(); try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.feature.start(poll: false)
        for (index, text) in ["alpha", "beta", "alpine"].enumerated() {
            fixture.source.value = .init(generation: index + 1, items: [.text(text)], application: "test.app")
            await fixture.feature.controller.refresh()
        }
        fixture.feature.present()
        try await Task.sleep(for: .milliseconds(80))
        let panel = try #require(fixture.presentation.panel)
        let editor = try #require(panel.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("alp", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(fixture.feature.controller.query == "alp")
        try press(125, characters: "\u{f701}", in: panel)
        #expect(fixture.feature.controller.selectedEntry?.plainText == "alpine")
        try press(125, characters: "\u{f701}", in: panel)
        #expect(fixture.feature.controller.selectedEntry?.plainText == "alpha")
        try press(126, characters: "\u{f700}", in: panel)
        #expect(fixture.feature.controller.selectedEntry?.plainText == "alpine")
        fixture.writer.result = .failed
        try press(36, characters: "\r", in: panel)
        #expect(fixture.writer.writes.last?.first?.representations["public.utf8-plain-text"] == Data("alpine".utf8))
        #expect(fixture.presentation.dismissals == 0)
        #expect(fixture.feature.controller.message == "复制失败，当前剪贴板可能已清空。")
        fixture.writer.result = .changed
        try press(36, characters: "\r", in: panel)
        #expect(fixture.presentation.dismissals == 0)
        #expect(fixture.feature.controller.message == "剪贴板已被其他应用修改，请重试。")
        fixture.writer.result = .copied(generation: 10)
        try press(36, characters: "\r", in: panel)
        #expect(fixture.presentation.dismissals == 1)
        let writesAfterSuccess = fixture.writer.writes.count
        fixture.feature.present()
        fixture.feature.controller.query = "no matches"
        try press(125, characters: "\u{f701}", in: panel)
        try press(36, characters: "\r", in: panel)
        #expect(fixture.feature.controller.selectedID == nil)
        #expect(fixture.writer.writes.count == writesAfterSuccess && fixture.presentation.dismissals == 1)
        let hiddenID = try #require(fixture.feature.controller.entries.first?.id)
        fixture.feature.copyAndClose(hiddenID)
        #expect(fixture.writer.writes.count == writesAfterSuccess && fixture.presentation.dismissals == 1)
        try press(53, characters: "\u{1b}", in: panel)
        #expect(fixture.presentation.dismissals == 2 && fixture.writer.writes.count == writesAfterSuccess)
        #expect(!panel.isVisible)
        await fixture.feature.shutdownAndWait()
    }
    @Test func markedTextKeepsNavigationReturnAndEscapeInTheNativeEditor() async throws {
        let fixture = ClipboardKeyboardFixture()
        defer { fixture.feature.shutdown(); try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.feature.start(poll: false)
        fixture.source.value = .init(generation: 1, items: [.text("中文合成内容")], application: "test.app")
        await fixture.feature.controller.refresh()
        fixture.feature.present()
        try await Task.sleep(for: .milliseconds(80))
        let panel = try #require(fixture.presentation.panel)
        let editor = try #require(panel.firstResponder as? NSTextView)
        for (keyCode, characters) in [(UInt16(125), "\u{f701}"), (126, "\u{f700}"), (36, "\r"), (53, "\u{1b}")] {
            editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(editor.hasMarkedText())
            try press(keyCode, characters: characters, in: panel)
            #expect(fixture.writer.writes.isEmpty && fixture.presentation.dismissals == 0)
            editor.unmarkText()
        }
        #expect(!panel.isVisible)
        await fixture.feature.shutdownAndWait()
    }
    @Test func hidingTheSelectedFavoriteClearsSelectionAndRequiresAVisibleRowToCopy() async throws {
        let source = MemoryClipboardSource(), writer = MemoryClipboardWriter()
        let controller = ClipboardController(source: source, writer: writer)
        await controller.enable()
        for (index, text) in ["alpha", "alpine", "unrelated"].enumerated() {
            source.value = .init(generation: index + 1, items: [.text(text)], application: "test.app")
            await controller.refresh()
        }
        let alpha = try #require(controller.entries.first { $0.plainText == "alpha" }?.id)
        let alpine = try #require(controller.entries.first { $0.plainText == "alpine" }?.id)
        await controller.toggleFavorite(alpha); await controller.toggleFavorite(alpine)
        controller.query = "alp"; controller.favoritesOnly = true
        controller.selectedID = alpine
        await controller.toggleFavorite(alpine)
        #expect(controller.selectedEntry == nil)
        controller.selectedID = alpha
        #expect(controller.copy(alpha))
        #expect(writer.writes.last?.first?.plainText == "alpha")
        await controller.toggleFavorite(alpine)
        await controller.delete(alpha)
        #expect(controller.selectedEntry == nil)
        await controller.shutdown()
    }
    @Test func visibleResultsRefreshAfterCaptureFavoriteAndDeletion() async throws {
        let source = MemoryClipboardSource()
        let controller = ClipboardController(source: source, writer: MemoryClipboardWriter())
        await controller.enable()
        source.value = .init(generation: 1, items: [.text("alpha")], application: "test.app")
        await controller.refresh()
        let alpha = try #require(controller.entries.first?.id)
        controller.query = "alp"
        #expect(controller.filteredEntries.map(\.plainText) == ["alpha"])
        source.value = .init(generation: 2, items: [.text("alpine")], application: "test.app")
        await controller.refresh()
        #expect(controller.filteredEntries.map(\.plainText) == ["alpine", "alpha"])
        controller.favoritesOnly = true
        #expect(controller.filteredEntries.isEmpty && controller.selectedEntry == nil)
        await controller.toggleFavorite(alpha)
        #expect(controller.filteredEntries.map(\.plainText) == ["alpha"])
        controller.selectedID = alpha
        #expect(controller.selectedEntry?.plainText == "alpha")
        await controller.delete(alpha)
        #expect(controller.filteredEntries.isEmpty && controller.selectedEntry == nil)
        controller.favoritesOnly = false
        #expect(controller.filteredEntries.map(\.plainText) == ["alpine"])
        await controller.shutdown()
    }
    private func press(_ keyCode: UInt16, characters: String, in panel: NSPanel) throws {
        let editor = try #require(panel.firstResponder as? NSTextView)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: panel.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        editor.keyDown(with: event)
    }
    private func searchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.placeholderString == V2L("搜索文字或来源应用") { return field }
        return view.subviews.lazy.compactMap { searchField(in: $0) }.first
    }
    @Test func filteringCannotLeaveAHiddenSelectionForPreviewOrCopy() async throws {
        let source = MemoryClipboardSource()
        let controller = ClipboardController(source: source, writer: MemoryClipboardWriter())
        await controller.enable()
        for (index, text) in ["alpha", "beta", "alpine"].enumerated() {
            source.value = .init(generation: index + 1, items: [.text(text)], application: "test.app")
            await controller.refresh()
        }
        controller.selectedID = controller.entries[1].id
        controller.query = "alp"
        #expect(controller.selectedEntry == nil)
        controller.query = "no matches"
        #expect(controller.selectedID == nil)
        #expect(controller.selectedEntry == nil)
        await controller.shutdown()
    }
}

@MainActor private final class HiddenClipboardPresentation {
    var panel: NSPanel?
    var dismissals = 0
    func present(_ panel: NSPanel) { self.panel = panel }
    func dismiss(_ panel: NSPanel) { dismissals += 1; panel.orderOut(nil) }
}
@MainActor private final class ClipboardKeyboardFixture {
    let source = MemoryClipboardSource()
    let writer = MemoryClipboardWriter()
    let presentation = HiddenClipboardPresentation()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-clipboard-keyboard-" + UUID().uuidString)
    let feature: ClipboardFeature
    init() {
        _ = NSApplication.shared
        let presentation = presentation
        feature = ClipboardFeature(directory: directory, source: source, writer: writer,
                                   presentWindow: { presentation.present($0) }, dismissWindow: { presentation.dismiss($0) })
    }
}
