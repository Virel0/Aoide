// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlaybackKit",
    // macOS is declared only so `swift test` runs the queue logic from the command
    // line without booting a simulator. The app ships iOS-only.
    platforms: [.iOS("26.0"), .macOS("14.0")],
    products: [
        .library(name: "PlaybackKit", targets: ["PlaybackKit"])
    ],
    targets: [
        .target(
            name: "PlaybackKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PlaybackKitTests",
            dependencies: ["PlaybackKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
