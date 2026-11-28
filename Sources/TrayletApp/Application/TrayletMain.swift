import AppKit

@main enum TrayletMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
        var evidence: URL?
        if arguments.count == 2, arguments[0] == "--v2-native-evidence", arguments[1].hasPrefix("/") {
            evidence = URL(fileURLWithPath: arguments[1], isDirectory: true)
        } else if !arguments.isEmpty {
            FileHandle.standardError.write(Data("Unsupported arguments; no application or clipboard session started.\n".utf8))
            exit(2)
        }
        let application = NSApplication.shared
        let delegate = ApplicationDelegate(evidenceDirectory: evidence)
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private let evidenceDirectory: URL?
    init(evidenceDirectory: URL? = nil) { self.evidenceDirectory = evidenceDirectory }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let evidenceDirectory {
            Task {
                do {
                    try await NativeEvidence.write(to: evidenceDirectory)
                    print("Synthetic native evidence completed; no production session started.")
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("Synthetic native evidence failed.\n".utf8)); exit(1)
                }
            }
            return
        }
        let coordinator = AppCoordinator(); self.coordinator = coordinator; coordinator.launch()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        coordinator?.requestTermination() ?? .terminateNow
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.handleReopen(hasVisibleWindows: flag) ?? false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
