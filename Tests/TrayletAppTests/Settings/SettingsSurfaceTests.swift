import AppKit
import SwiftUI
import Testing
@testable import TrayletApp

@Suite("Settings surface regression") @MainActor struct SettingsSurfaceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAYLET_SETTINGS_SURFACE_DIR"] != nil))
    func nativeWindowSurfacesAcrossGlassAndSectionChanges() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TRAYLET_SETTINGS_SURFACE_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let originalGlass = AppearanceState.shared.glassEnabled
        let originalAppearance = NSApp.appearance
        defer { AppearanceState.shared.glassEnabled = originalGlass; NSApp.appearance = originalAppearance }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("traylet-surface-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let clipboard = ClipboardFeature(directory: temporary, source: SurfaceClipboardSource(), writer: SurfaceClipboardWriter())
        let preferences = PreferencesStore()
        let shortcuts = ShortcutManager(preferences: preferences, driver: SurfaceShortcuts())
        let translation = TranslationConfiguration()
        let navigation = SettingsNavigation()
        let actions = SettingsActions(preferences: preferences, login: SurfaceLogin())
        var samples: [[String: String]] = []
        for scheme in [ColorScheme.light, .dark] {
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let view = SettingsWorkspaceView(preferences: preferences, shortcuts: shortcuts, translation: translation,
                languagePacks: TranslationLanguagePackController(), clipboard: clipboard, navigation: navigation, actions: actions, localization: Localization(languageCode: "zh-Hans"))
                .environment(\.colorScheme, scheme).transaction { $0.disablesAnimations = true }
            let host = GlassWindowBacking.hostingView(view, fullBleed: true)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 650),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let originalWindowShadow = window.hasShadow
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            AppearanceState.shared.glassEnabled = false
            let backing = GlassWindowBacking(window: window, content: host, fullBleedTitlebar: true)
            for (step, enabled) in [false, true, false, true, false].enumerated() {
                var value = preferences.value; value.glassEnabled = enabled; try preferences.save(value)
                AppearanceState.shared.glassEnabled = enabled
                backing.apply()
                for section in SettingsSection.allCases {
                    navigation.navigate(to: section)
                    try await Task.sleep(for: .milliseconds(160))
                    window.contentView?.layoutSubtreeIfNeeded(); host.layoutSubtreeIfNeeded()
                    let content = try #require(window.contentView)
                    let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                    window.effectiveAppearance.performAsCurrentDrawingAppearance {
                        content.cacheDisplay(in: content.bounds, to: bitmap)
                        // NSView's cache omits NSWindow's own background; include that real semantic backdrop.
                        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                            context.cgContext.setBlendMode(.destinationOver)
                            context.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
                            context.cgContext.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
                        }
                    }
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    let name = "\(scheme == .dark ? "dark" : "light")-\(enabled ? "glass" : "solid")-\(step)-\(section.rawValue)"
                    try png.write(to: output.appendingPathComponent(name + ".png"))
                    #expect(!window.isVisible && png.count > 5_000)
                    #expect(window.isOpaque == !AppearanceState.shared.glassActive)
                    #expect(window.hasShadow == originalWindowShadow)
                    if #available(macOS 26, *) {
                        #expect((window.contentView is NSGlassEffectView) == AppearanceState.shared.glassActive)
                    }
                    if !enabled {
                        let scale = CGFloat(bitmap.pixelsWide) / content.bounds.width
                        for y in [420, 500, 580] {
                            let sidebarA = try #require(bitmap.colorAt(x: Int(40 * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.deviceRGB))
                            let sidebarB = try #require(bitmap.colorAt(x: Int(200 * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.deviceRGB))
                            let sidebarDelta = max(abs(sidebarA.redComponent - sidebarB.redComponent), abs(sidebarA.greenComponent - sidebarB.greenComponent), abs(sidebarA.blueComponent - sidebarB.blueComponent))
                            #expect(sidebarDelta < 1.0 / 255, "Solid sidebar plane has an internal edge: \(name), row \(y), delta \(sidebarDelta)")
                        }
                        for y in [300, 450, 550] {
                            let contentA = try #require(bitmap.colorAt(x: Int(228 * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.deviceRGB))
                            let contentB = try #require(bitmap.colorAt(x: Int(236 * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.deviceRGB))
                            let contentDelta = max(abs(contentA.redComponent - contentB.redComponent), abs(contentA.greenComponent - contentB.greenComponent), abs(contentA.blueComponent - contentB.blueComponent))
                            #expect(contentDelta < 1.0 / 255, "Solid content plane has an internal edge: \(name), row \(y), delta \(contentDelta)")
                        }
                        let seamSidebar = try #require(bitmap.colorAt(x: Int(200 * scale), y: Int(420 * scale))?.usingColorSpace(.deviceRGB))
                        let seamContent = try #require(bitmap.colorAt(x: Int(232 * scale), y: Int(420 * scale))?.usingColorSpace(.deviceRGB))
                        let seamContrast = max(abs(seamSidebar.redComponent - seamContent.redComponent), abs(seamSidebar.greenComponent - seamContent.greenComponent), abs(seamSidebar.blueComponent - seamContent.blueComponent))
                        #expect(seamContrast > 0.01 && seamContrast < 0.08, "Solid sidebar/content contrast should be subtle and harmonious: \(name), delta \(seamContrast)")
                    }
                    var colors: [String] = []
                    for x in [220, 222, 224, 225, 226, 228, 232] {
                        let scale = CGFloat(bitmap.pixelsWide) / content.bounds.width
                        let color = bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(300 * scale))?.usingColorSpace(.deviceRGB)
                        colors.append("\(x):\(color?.redComponent ?? -1),\(color?.greenComponent ?? -1),\(color?.blueComponent ?? -1)")
                    }
                    samples.append(["name": name, "colors": colors.joined(separator: ";")])
                }
            }
            window.contentView = nil; window.close()
        }
        try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("boundary-samples.json"))
        #expect(!clipboard.controller.enabled && translation.credential.isEmpty && !translation.isBusy)
        await clipboard.shutdownAndWait()
    }
}

@MainActor private final class SurfaceLogin: LoginItemManaging {
    var enabled = false; var requiresApproval = false
    func setEnabled(_ value: Bool) throws { enabled = value }
}
@MainActor private final class SurfaceShortcuts: ShortcutRegistering {
    var onInvoke: ((Action) -> Void)?
    func prepare(_ bindings: [ShortcutAssignment]) throws -> any ShortcutUpdate { SurfaceShortcutUpdate() }
    func stop() {}
}
@MainActor private final class SurfaceShortcutUpdate: ShortcutUpdate { func commit() {}; func cancel() {} }
@MainActor private final class SurfaceClipboardSource: ClipboardSource {
    var generation = 0
    func read(expectedGeneration: Int, excluding: Set<String>) -> ClipboardSnapshot? { nil }
}
@MainActor private final class SurfaceClipboardWriter: ClipboardWriting {
    func write(_ items: [ClipboardContent], marker: String) -> ClipboardWriteResult { .failed }
}
