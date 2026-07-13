// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MyTimer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MyTimer", path: "Sources/MyTimer")
    ]
)
