// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AudioRouter",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "AudioRouter",
            path: "Sources/AudioRouter",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudioKit"),
            ]
        )
    ]
)
