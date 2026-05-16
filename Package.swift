// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SJAudioBridge",
    platforms: [
        // ScreenCaptureKit audio capture (SCStreamConfiguration.capturesAudio)
        // is macOS 13+, but we target 14 for the matured audio sample path.
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "SJAudioBridge",
            path: "Sources/SJAudioBridge",
            resources: [
                .process("Resources"),
            ])
    ]
)
