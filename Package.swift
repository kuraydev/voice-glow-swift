// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceGlowKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VoiceGlowKit", targets: ["VoiceGlowKit"])
    ],
    targets: [
        .target(name: "VoiceGlowKit"),
        .testTarget(
            name: "VoiceGlowKitTests",
            dependencies: ["VoiceGlowKit"],
            resources: [.copy("Resources/voice-golden.json")]
        )
    ]
)
