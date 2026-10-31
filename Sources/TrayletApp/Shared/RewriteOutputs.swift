import AppKit
import TrayletCore

enum CopyOutcome: Equatable, Sendable { case copied, changed, failed }

@MainActor protocol TextOutputWriting {
    func copyText(_ text: String) -> CopyOutcome
}

@MainActor protocol ImageOutputWriting {
    func copyImage(_ image: RasterImage) -> CopyOutcome
}

/// Write-only user actions; no prior clipboard body or credential is read.
@MainActor final class V2SystemClipboardWriter: TextOutputWriting, ImageOutputWriting {
    private let name: NSPasteboard.Name?
    init(privatePasteboardName: NSPasteboard.Name? = nil) { name = privatePasteboardName }

    func copyText(_ text: String) -> CopyOutcome {
        guard !text.isEmpty, text.utf8.count <= 4 * 1_024 * 1_024 else { return .failed }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return .failed }
        return write(item)
    }

    func copyImage(_ image: RasterImage) -> CopyOutcome {
        let item = NSPasteboardItem()
        guard item.setData(image.pngData, forType: .png) else { return .failed }
        return write(item)
    }

    private func write(_ item: NSPasteboardItem) -> CopyOutcome {
        let board = name.map(NSPasteboard.init(name:)) ?? .general
        let generation = board.clearContents()
        guard board.changeCount == generation else { return .changed }
        let success = board.writeObjects([item])
        guard board.changeCount == generation else { return .changed }
        return success ? .copied : .failed
    }
}
