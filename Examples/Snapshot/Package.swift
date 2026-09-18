// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Snapshot",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "Snapshot",
            dependencies: [.product(name: "VoiceGlowKit", package: "voice-glow-swift")]
        )
    ]
)
