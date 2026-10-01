// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeDeck", path: "Sources/ClaudeDeck")
    ]
)
