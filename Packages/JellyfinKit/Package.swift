// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JellyfinKit",
    // macOS is declared purely so `swift build`/`swift test` work from the command
    // line without booting a simulator. The app itself only ever ships for iOS.
    platforms: [.iOS("26.0"), .macOS("14.0")],
    products: [
        .library(name: "JellyfinKit", targets: ["JellyfinKit"])
    ],
    targets: [
        .target(
            name: "JellyfinKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JellyfinKitTests",
            dependencies: ["JellyfinKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
