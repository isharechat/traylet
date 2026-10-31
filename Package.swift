// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Traylet",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Traylet", targets: ["TrayletApp"])],
    targets: [
        .target(name: "TrayletCore"),
        .executableTarget(name: "TrayletApp", dependencies: ["TrayletCore"], exclude: ["Capture/Scrolling"], resources: [.copy("Resources/TrayletAppIcon.png")]),
        .testTarget(name: "TrayletAppTests", dependencies: ["TrayletCore", "TrayletApp"], exclude: ["Scrolling"])
    ]
)
