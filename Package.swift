// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Brahma",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BrahmaCore", targets: ["BrahmaCore"]),
        .executable(name: "brahma", targets: ["brahma"]),
        .executable(name: "brahma-pdf", targets: ["brahma-pdf"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // The one caller of the variadic `sandbox_check` (what another process's sandbox allows); a stub off macOS.
        .target(name: "CSandboxCheck"),
        .target(
            name: "BrahmaCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift"), "CSandboxCheck"]
        ),
        // Platform owner-key hash store (macOS Keychain); kept out of BrahmaCore so the core stays portable.
        .target(name: "BrahmaKeychain", dependencies: ["BrahmaCore"]),
        .target(name: "BrahmaAppModel", dependencies: ["BrahmaCore", "BrahmaKeychain"]),
        // SpriteKit/Metal rendering of the live map: the only place besides BrahmaApp that imports AppKit or SpriteKit.
        .target(name: "BrahmaMapKit", dependencies: ["BrahmaAppModel"]),
        .executableTarget(name: "BrahmaApp", dependencies: ["BrahmaAppModel", "BrahmaKeychain", "BrahmaMapKit"]),
        .executableTarget(
            name: "brahma",
            dependencies: [
                "BrahmaCore", "BrahmaKeychain",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // The sandboxed PDF extraction helper (C2b, ruling 33): PDFKit and CoreGraphics decode a PDF outside the engine, under
        // Seatbelt; BrahmaCore never parses a PDF. Foundation, PDFKit and CoreGraphics only (nothing of Brahma's own).
        .executableTarget(name: "brahma-pdf"),
        .testTarget(
            name: "BrahmaCoreTests",
            dependencies: ["BrahmaCore", "BrahmaKeychain"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "BrahmaAppModelTests", dependencies: ["BrahmaAppModel", "BrahmaKeychain"]),
        .testTarget(name: "BrahmaMapKitTests", dependencies: ["BrahmaMapKit", "BrahmaKeychain"]),
    ]
)
