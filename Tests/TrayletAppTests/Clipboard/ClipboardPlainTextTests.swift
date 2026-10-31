import AppKit
import Testing
@testable import TrayletApp

@Suite("Clipboard Plain Text") @MainActor struct ClipboardPlainTextTests {
    @Test func privatePasteboardStripsFormattingPreservesOriginalAndDoesNotSelfCapture() async throws {
        let name = NSPasteboard.Name("local.traylet.plain-text." + UUID().uuidString)
        let board = NSPasteboard(name: name)
        defer { board.releaseGlobally() }
        board.clearContents()
        let source = V2ClipboardNativeSource(privatePasteboardName: name, application: { "synthetic.app" })
        let store = ClipboardController(source: source, writer: V2ClipboardNativeWriter(privatePasteboardName: name))
        await store.enable()
        let first = NSPasteboardItem()
        first.setString("  Hello\nworld  ", forType: .string)
        first.setString("<b>Hello world</b>", forType: .html)
        first.setString("{\\rtf1 Hello world}", forType: .rtf)
        let second = NSPasteboardItem(); second.setString("第二段\n", forType: .string)
        board.clearContents(); try #require(board.writeObjects([first, second]))
        await store.refresh()
        let entry = try #require(store.entries.first)
        #expect(store.copy(entry.id, format: .plainText))
        #expect(board.string(forType: .string) == "  Hello\nworld  \n第二段\n")
        #expect(board.pasteboardItems?.count == 1)
        #expect(board.data(forType: .html) == nil && board.data(forType: .rtf) == nil)
        await store.refresh()
        #expect(store.entries.count == 1 && store.entries.first?.items == entry.items)
        #expect(store.copy(entry.id))
        #expect(board.pasteboardItems?.count == 2)
        #expect(board.pasteboardItems?.first?.string(forType: .string) == "  Hello\nworld  ")
        #expect(board.pasteboardItems?.last?.string(forType: .string) == "第二段\n")
        #expect(board.data(forType: .html) != nil && board.data(forType: .rtf) != nil)
        await store.shutdown()
    }
    @Test func hiddenImageOnlyAndOverBudgetTextNeverReachTheWriter() async throws {
        let source = MemoryClipboardSource(), writer = MemoryClipboardWriter()
        let store = ClipboardController(source: source, writer: writer)
        await store.enable()
        source.value = .init(generation: 1, items: [.text("hidden")], application: "test.app")
        await store.refresh()
        let hidden = try #require(store.entries.first?.id)
        store.query = "absent"
        #expect(!store.copy(hidden, format: .plainText) && writer.writes.isEmpty)
        store.query = ""
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        source.value = .init(generation: 2, items: [.init(representations: ["public.png": png])], application: "test.app")
        await store.refresh()
        #expect(!store.copy(try #require(store.entries.first?.id), format: .plainText) && writer.writes.isEmpty)
        let halfBudget = ClipboardContent.text(String(repeating: "x", count: ClipboardPolicy.itemBytes / 2))
        source.value = .init(generation: 3, items: [halfBudget, halfBudget], application: "test.app")
        await store.refresh()
        #expect(store.entries.first?.byteCount == ClipboardPolicy.itemBytes)
        #expect(!store.copy(try #require(store.entries.first?.id), format: .plainText) && writer.writes.isEmpty)
        await store.shutdown()
    }
    @Test func failuresKeepTheEntryAndDoNotRetryOverANewerClipboard() async throws {
        let source = MemoryClipboardSource(), writer = MemoryClipboardWriter()
        let store = ClipboardController(source: source, writer: writer)
        await store.enable()
        source.value = .init(generation: 1, items: [.text("  synthetic text  ")], application: "test.app")
        await store.refresh()
        let id = try #require(store.entries.first?.id)
        writer.result = .failed
        #expect(!store.copy(id, format: .plainText))
        #expect(store.message == "复制失败，当前剪贴板可能已清空。" && store.entries.count == 1)
        writer.result = .changed
        #expect(!store.copy(id, format: .plainText))
        #expect(store.message == "剪贴板已被其他应用修改，请重试。" && store.entries.count == 1)
        #expect(writer.writes.count == 2 && writer.writes.allSatisfy { $0 == [.text("  synthetic text  ")] })
        await store.shutdown()
    }
}
