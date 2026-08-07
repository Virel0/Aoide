// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CurationKit",
    // macOS is declared only so `swift test` runs the store from the command line
    // without booting a simulator. The app ships iOS-only.
    platforms: [.iOS("26.0"), .macOS("14.0")],
    products: [
        .library(name: "CurationKit", targets: ["CurationKit"])
    ],
    dependencies: [
        // The project's first external dependency, and declared here rather than in
        // the app so the hand-written pbxproj stays untouched. Hand-rolling
        // migrations, statement caching and write serialisation over the raw SQLite
        // C API is a lot of code whose bugs would be silent data corruption.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Apple's own drop-in for CryptoKit, which does not exist off Apple platforms.
        // Pulled in only on Linux, so an iOS build keeps using the system framework
        // and gains no dependency for a portability it does not need.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "CurationKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CurationKitTests",
            dependencies: ["CurationKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
