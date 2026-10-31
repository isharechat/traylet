import AppKit

@MainActor enum V2MenuFactory {
    static func make(bindings: [V2ShortcutAssignment], english: Bool = false, target: AnyObject? = nil,
                     action: Selector? = nil) -> NSMenu {
        let menu = NSMenu(title: "Traylet")
        let rows: [(V2Action, String, String)] = [(.regionCapture, "crop", "Region Capture"), (.screenCapture, "display", "Screen Capture"),
            (.inputTranslation, "character.bubble", "Translate Text"), (.captureTranslation, "viewfinder", "Translate Screenshot"),
            (.clipboard, "doc.on.clipboard", "Clipboard")]
        for (index, row) in rows.enumerated() {
            if index == 2 || index == 4 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: english ? row.2 : row.0.title, action: action, keyEquivalent: "")
            item.target = target; item.representedObject = row.0.rawValue
            item.image = NSImage(systemSymbolName: row.1, accessibilityDescription: item.title)
            if let chord = bindings.first(where: { $0.action == row.0 })?.chord { assign(chord, to: item) }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, id, symbol, key) in [(english ? "Settings" : "设置", "settings", "gearshape", ","),
                                       (english ? "Quit" : "退出", "quit", "power", "q")] {
            if id == "quit" { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command]; item.target = target; item.representedObject = id
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); menu.addItem(item)
        }
        return menu
    }
    private static func assign(_ chord: V2KeyChord, to item: NSMenuItem) {
        var flags: NSEvent.ModifierFlags = []
        if chord.modifiers.contains(.control) { flags.insert(.control) }
        if chord.modifiers.contains(.option) { flags.insert(.option) }
        if chord.modifiers.contains(.shift) { flags.insert(.shift) }
        if chord.modifiers.contains(.command) { flags.insert(.command) }
        let labels: [UInt16: String] = [36:"\r",48:"\t",49:" ",51:"\u{8}",76:"\u{3}",117:"\u{7f}",
            123:"\u{f702}",124:"\u{f703}",125:"\u{f701}",126:"\u{f700}",115:"\u{f729}",119:"\u{f72b}",116:"\u{f72c}",121:"\u{f72d}",
            122:"\u{f704}",120:"\u{f705}",99:"\u{f706}",118:"\u{f707}",96:"\u{f708}",97:"\u{f709}",98:"\u{f70a}",100:"\u{f70b}",101:"\u{f70c}",109:"\u{f70d}",103:"\u{f70e}",111:"\u{f70f}"]
        let printable = V2KeyChord(keyCode: chord.keyCode, modifiers: []).display
        if let key = labels[chord.keyCode] ?? (printable.count == 1 ? printable.lowercased() : nil) {
            item.keyEquivalent = key; item.keyEquivalentModifierMask = flags
        } else {
            // Unknown hardware keys still expose the exact configured binding, right aligned.
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 290)]
            item.attributedTitle = NSAttributedString(string: item.title + "\t" + chord.display,
                attributes: [.paragraphStyle: paragraph, .font: NSFont.menuFont(ofSize: 0)])
        }
    }
}
