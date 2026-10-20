// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentCompany",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentCompanyCore", targets: ["AgentCompanyCore"]),
        .executable(name: "agentco", targets: ["agentco"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "AgentCompanyCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "agentco",
            dependencies: [
                "AgentCompanyCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "AgentCompanyCoreTests",
            dependencies: ["AgentCompanyCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
