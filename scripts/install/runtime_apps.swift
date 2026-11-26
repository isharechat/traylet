import AppKit
import Foundation

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.finishLaunching()
let workspace = NSWorkspace.shared
let all = workspace.runningApplications
let front = workspace.frontmostApplication
let rows: [[String: Any]] = all.filter { $0.bundleIdentifier == "local.traylet.app" && !$0.isTerminated }.map {
    let bundle = $0.bundleURL.flatMap(Bundle.init(url:))
    return ["pid": $0.processIdentifier, "bundlePath": $0.bundleURL?.path ?? "",
            "version": bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "active": $0.isActive, "unsavedEdits": "unknown"]
}
let result: [String: Any] = ["available": !all.isEmpty && front != nil,
                           "apps": rows, "reason": (!all.isEmpty && front != nil) ? "" : "GUI application inventory unavailable"]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
