// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Brahma",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BrahmaCore", targets: ["BrahmaCore"]),
        .executable(name: "brahma", targets: ["brahma"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "BrahmaCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Platform owner-key hash store (macOS Keychain); kept out of BrahmaCore so the core stays portable.
        .target(name: "BrahmaKeychain", dependencies: ["BrahmaCore"]),
        .target(name: "BrahmaAppModel", dependencies: ["BrahmaCore", "BrahmaKeychain"]),
        .executableTarget(name: "BrahmaApp", dependencies: ["BrahmaAppModel", "BrahmaKeychain"]),
        .executableTarget(
            name: "brahma",
            dependencies: [
                "BrahmaCore", "BrahmaKeychain",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "BrahmaCoreTests",
            dependencies: ["BrahmaCore", "BrahmaKeychain"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "BrahmaAppModelTests", dependencies: ["BrahmaAppModel", "BrahmaKeychain"]),
    ]
)
