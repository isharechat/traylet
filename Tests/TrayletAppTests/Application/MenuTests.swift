import AppKit
import Testing
@testable import TrayletApp

@MainActor struct MenuTests {
    @Test func menuHasOnlyCurrentActionsWithNativeImagesAndAssignedShortcuts() {
        let menu = V2MenuFactory.make(bindings: V2ShortcutAssignment.defaults)
        let actions = menu.items.filter { !$0.isSeparatorItem }
        #expect(actions.map(\.title) == ["区域截图", "屏幕截图", "输入翻译", "截图翻译", "剪贴板", "设置", "退出"])
        #expect(actions.allSatisfy { $0.image != nil })
        #expect(actions[0].keyEquivalent == "1")
        #expect(actions[0].keyEquivalentModifierMask == [.control, .option])
        #expect(actions[1].keyEquivalent.isEmpty)
        #expect(actions[5].keyEquivalent == "," && actions[6].keyEquivalent == "q")
        #expect(menu.items.filter(\.isSeparatorItem).count == 4)
    }
}
