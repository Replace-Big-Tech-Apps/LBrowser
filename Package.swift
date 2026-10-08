// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LBrowser",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "LBrowser", path: "Sources/LBrowser"),
        .testTarget(name: "LBrowserTests", dependencies: ["LBrowser"])
    ]
)
