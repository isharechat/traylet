import AppKit
import Testing
@testable import TrayletApp

@Suite("Same-binary native evidence") @MainActor
struct NativeEvidenceTests {
    @Test func writesValidSyntheticPNGsWithoutPresentingWindows() async throws {
        let retainedOutput = ProcessInfo.processInfo.environment["TRAYLET_V2_NATIVE_EVIDENCE_TEST_DIR"]
        let directory = retainedOutput.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("traylet-v2-evidence-test-" + UUID().uuidString)
        defer { if retainedOutput == nil { try? FileManager.default.removeItem(at: directory) } }
        _ = NSApplication.shared
        let visibleBefore = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        try await V2NativeEvidence.write(to: directory)
        let data = try Data(contentsOf: directory.appendingPathComponent("evidence-report.json"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["passed"] as? Bool == true)
        #expect(json["scope"] as? String == "syntheticOffscreen")
        #expect(json["syntheticOnly"] as? Bool == true)
        for key in ["externalRequests", "generalClipboardReads", "systemTranslationCalls", "visionCalls", "speechCalls", "registeredSystemShortcuts", "windowsShown"] {
            #expect(json[key] as? Int == 0)
        }
        let images = try #require(json["images"] as? [[String: Any]])
        #expect(images.count == 46)
        #expect(Set(images.compactMap { $0["name"] as? String }).count == images.count)
        for record in images {
            let name = try #require(record["name"] as? String)
            let imageData = try Data(contentsOf: directory.appendingPathComponent(name))
            let image = try #require(NSBitmapImageRep(data: imageData))
            #expect(image.pixelsWide == record["width"] as? Int)
            #expect(image.pixelsHigh == record["height"] as? Int)
            #expect(imageData.count == record["byteCount"] as? Int)
            #expect(record["windowWasVisible"] as? Bool == false)
            #expect(imageData.count > 1000)
            if name == "translation-light.png" || name == "translation-dark.png" {
                let background = try #require(image.colorAt(x: 0, y: 0))
                #expect(background.alphaComponent > 0.99, "Offscreen translation evidence needs a semantic window backdrop; transparent black text is not visually inspectable.")
            }
            // Distinct native foreground and background pixels, not a transparent or flat export.
            var colors = Set<String>()
            // Include small captions and icons in sparse empty states; a 25×25 grid can miss all glyph edges.
            for y in stride(from: 0, to: image.pixelsHigh, by: max(1, image.pixelsHigh / 128)) {
                for x in stride(from: 0, to: image.pixelsWide, by: max(1, image.pixelsWide / 128)) {
                    if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                        colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255)),\(Int(color.alphaComponent * 255))")
                    }
                }
            }
            // Translation capture has no toolbar by design: image, dimmed shade and selection chrome only.
            #expect(colors.count > (name.hasPrefix("editor-translation-mode") ? 2 : 3), "Native view must contain visible content: \(name)")
        }
        #expect(Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)) == visibleBefore)
    }
}
