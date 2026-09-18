// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceGlowDemo",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "VoiceGlowDemo",
            dependencies: [.product(name: "VoiceGlowKit", package: "voice-glow-swift")]
        )
    ]
)
