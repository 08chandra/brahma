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
        .target(name: "BrahmaAppModel", dependencies: ["BrahmaCore"]),
        .executableTarget(name: "BrahmaApp", dependencies: ["BrahmaAppModel"]),
        .executableTarget(
            name: "brahma",
            dependencies: [
                "BrahmaCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "BrahmaCoreTests",
            dependencies: ["BrahmaCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "BrahmaAppModelTests", dependencies: ["BrahmaAppModel"]),
    ]
)
