// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DockLite",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DockLite", path: "Sources/DockLite")
    ]
)
