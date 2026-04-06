// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Heimdall",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Heimdall",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("ScriptingBridge"),
            ]
        ),
    ]
)
