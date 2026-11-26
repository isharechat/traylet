import AppKit
import Testing
@testable import TrayletApp

@Suite("Editing color panel") @MainActor struct EditingColorWellTests {
    @Test func activationRaisesPanelAfterAppKitAndRestoresState() {
        _ = NSApplication.shared
        let panel = NSColorPanel.shared
        panel.orderOut(nil)
        let level = panel.level, behavior = panel.collectionBehavior
        let hides = panel.hidesOnDeactivate, alpha = panel.showsAlpha
        let owner = EditingColorPanel()
        let oldAccessory = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        let originalAccessory = panel.accessoryView
        panel.accessoryView = oldAccessory
        let well = EditingNativeColorWell(panel:owner)
        let window = NSWindow(contentRect:NSRect(x:100,y:100,width:200,height:100),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.level = .screenSaver
        window.contentView = well
        defer { owner.close(); panel.accessoryView = originalAccessory; window.contentView = nil; window.close() }
        for _ in 0..<2 {
            well.activate(true)
            #expect(well.isActive && panel.isVisible)
            #expect(panel.level.rawValue == window.level.rawValue+1)
            #expect(!panel.showsAlpha)
            #expect(panel.accessoryView is EditingColorPaletteView)
            owner.close()
            #expect(!well.isActive && !panel.isVisible)
            #expect(panel.level == level && panel.collectionBehavior == behavior)
            #expect(panel.hidesOnDeactivate == hides && panel.showsAlpha == alpha)
            #expect(panel.accessoryView === oldAccessory)
        }
        well.activate(true)
        window.contentView = nil
        #expect(!panel.isVisible && panel.level == level)
    }

    @Test func visiblePanelIsPreservedOnRelease() {
        _ = NSApplication.shared
        let panel = NSColorPanel.shared
        panel.orderFront(nil)
        let level = panel.level
        let well = EditingNativeColorWell(panel:EditingColorPanel())
        let window = NSWindow(contentRect:NSRect(x:100,y:100,width:200,height:100),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = well
        defer { well.deactivate(); panel.orderOut(nil); window.contentView = nil; window.close() }
        well.activate(true); well.deactivate()
        #expect(panel.isVisible && panel.level == level)
    }
}
