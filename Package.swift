// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Hive",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "Hive", targets: ["Hive"]),
        .library(name: "HiveCore", targets: ["HiveCore"]),
        .library(name: "HiveDSL", targets: ["HiveDSL"]),
        .library(name: "HiveConduit", targets: ["HiveConduit"]),
        .library(name: "HiveCheckpointWax", targets: ["HiveCheckpointWax"]),
        .library(name: "HiveSwiftAgents", targets: ["HiveSwiftAgents"]),
        .executable(name: "HiveTinyGraphExample", targets: ["HiveTinyGraphExample"]),
    ],
    dependencies: [
        .package(url: "https://github.com/christopherkarani/Conduit", from: "0.3.1"),
        .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.3"),
    ],
    targets: [
        .target(
            name: "HiveCore",
            path: "Sources/Hive/Sources/HiveCore",
            exclude: [
                "README.md",
                "CLAUDE.md",
                "Checkpointing/CLAUDE.md",
                "Errors/CLAUDE.md",
                "Graph/CLAUDE.md",
                "HybridInference/CLAUDE.md",
                "Runtime/CLAUDE.md",
                "Schema/CLAUDE.md",
                "Store/CLAUDE.md",
            ]
        ),
        .target(
            name: "HiveDSL",
            dependencies: ["HiveCore"],
            path: "Sources/Hive/Sources/HiveDSL",
            exclude: ["CLAUDE.md"]
        ),
        .target(
            name: "HiveConduit",
            dependencies: [
                "HiveCore",
                .product(name: "Conduit", package: "Conduit"),
            ],
            path: "Sources/Hive/Sources/HiveConduit",
            exclude: ["README.md", "CLAUDE.md"]
        ),
        .target(
            name: "HiveCheckpointWax",
            dependencies: [
                "HiveCore",
                .product(name: "Wax", package: "Wax"),
            ],
            path: "Sources/Hive/Sources/HiveCheckpointWax",
            exclude: ["README.md", "CLAUDE.md"]
        ),
        .target(
            name: "HiveSwiftAgents",
            dependencies: ["HiveCore"],
            path: "Sources/Hive/Sources/HiveSwiftAgents",
            exclude: ["README.md"]
        ),
        .target(
            name: "Hive",
            dependencies: [
                "HiveCore",
                "HiveDSL",
                "HiveConduit",
                "HiveCheckpointWax",
            ],
            path: "Sources/Hive/Sources/Hive",
            exclude: ["README.md", "CLAUDE.md"]
        ),
        .executableTarget(
            name: "HiveTinyGraphExample",
            dependencies: ["HiveCore"],
            path: "Sources/Hive/Examples/TinyGraph",
            exclude: ["CLAUDE.md"]
        ),
        .testTarget(
            name: "HiveCoreTests",
            dependencies: ["HiveCore"],
            path: "Sources/Hive/Tests/HiveCoreTests",
            exclude: ["Runtime/CLAUDE.md"],
            swiftSettings: [
                .define("HIVE_V11_TRIGGERS"),
            ]
        ),
        .testTarget(
            name: "HiveDSLTests",
            dependencies: ["HiveDSL"],
            path: "Sources/Hive/Tests/HiveDSLTests",
            exclude: ["CLAUDE.md"]
        ),
        .testTarget(
            name: "HiveConduitTests",
            dependencies: [
                "HiveConduit",
                "HiveDSL",
            ],
            path: "Sources/Hive/Tests/HiveConduitTests"
        ),
        .testTarget(
            name: "HiveCheckpointWaxTests",
            dependencies: ["HiveCheckpointWax"],
            path: "Sources/Hive/Tests/HiveCheckpointWaxTests"
        ),
        .testTarget(
            name: "HiveSwiftAgentsTests",
            dependencies: ["HiveSwiftAgents"],
            path: "Sources/Hive/Tests/HiveSwiftAgentsTests"
        ),
        .testTarget(
            name: "HiveTests",
            dependencies: ["Hive"],
            path: "Sources/Hive/Tests/HiveTests"
        ),
    ]
)
