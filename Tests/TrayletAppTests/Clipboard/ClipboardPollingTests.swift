import Combine
import Foundation
import Testing
@testable import TrayletApp

@Suite("Clipboard Polling") @MainActor struct ClipboardPollingTests {
    @Test func idlePollsPublishNothingSoOpenListsDoNotRedraw() async {
        let source = PollingSource()
        let controller = ClipboardController(source: source, writer: PollingWriter())
        await controller.enable()
        source.generation = 1; source.next = V2ClipboardSnapshot(generation: 1, items: [.text("第一条")], application: "com.example")
        await controller.refresh()
        let id = controller.entries.first?.id
        controller.selectedID = id
        var publishes = 0
        let watch = controller.objectWillChange.sink { publishes += 1 }
        for _ in 0..<5 { await controller.refresh() }
        withExtendedLifetime(watch) {}
        #expect(publishes == 0 && controller.entries.count == 1 && controller.selectedID == id)
        #expect(controller.display(controller.entries[0]).line == "第一条" && controller.display(controller.entries[0]).kind == .text)
    }

    @Test func expiredEntriesStillLeaveOnPoll() async {
        var now = Date()
        let source = PollingSource()
        let controller = ClipboardController(source: source, writer: PollingWriter(), clock: { now })
        await controller.enable()
        source.generation = 1; source.next = V2ClipboardSnapshot(generation: 1, items: [.text("https://example.com/a")], application: "com.example")
        await controller.refresh()
        #expect(controller.display(controller.entries[0]).kind == .link)
        now = now.addingTimeInterval(8 * 86400)
        await controller.refresh()
        #expect(controller.entries.isEmpty)
    }
}

@MainActor private final class PollingSource: ClipboardSource {
    var generation = 0
    var next: V2ClipboardSnapshot?
    func read(expectedGeneration: Int, excluding: Set<String>) -> V2ClipboardSnapshot? { next }
}
@MainActor private final class PollingWriter: ClipboardWriting {
    func write(_ items: [ClipboardContent], marker: String) -> ClipboardWriteResult { .failed }
}
