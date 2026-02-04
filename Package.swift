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
        .library(name: "HiveConduit", targets: ["HiveConduit"]),
        .library(name: "HiveCheckpointWax", targets: ["HiveCheckpointWax"]),
        .executable(name: "HiveTinyGraphExample", targets: ["HiveTinyGraphExample"]),
    ],
    dependencies: [
        .package(path: "../Conduit"),
        .package(path: "../rag/Wax"),
    ],
    targets: [
        .target(
            name: "HiveCore",
            path: "Sources/Hive/Sources/HiveCore",
            exclude: ["README.md"]
        ),
        .target(
            name: "HiveConduit",
            dependencies: [
                "HiveCore",
                .product(name: "Conduit", package: "Conduit"),
            ],
            path: "Sources/Hive/Sources/HiveConduit",
            exclude: ["README.md"]
        ),
        .target(
            name: "HiveCheckpointWax",
            dependencies: [
                "HiveCore",
                .product(name: "Wax", package: "Wax"),
            ],
            path: "Sources/Hive/Sources/HiveCheckpointWax",
            exclude: ["README.md"]
        ),
        .target(
            name: "Hive",
            dependencies: [
                "HiveCore",
                "HiveConduit",
                "HiveCheckpointWax",
            ],
            path: "Sources/Hive/Sources/Hive",
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "HiveTinyGraphExample",
            dependencies: ["HiveCore"],
            path: "Sources/Hive/Examples/TinyGraph"
        ),
        .testTarget(
            name: "HiveCoreTests",
            dependencies: ["HiveCore"],
            path: "Sources/Hive/Tests/HiveCoreTests",
            swiftSettings: [
                .define("HIVE_V11_TRIGGERS"),
            ]
        ),
        .testTarget(
            name: "HiveConduitTests",
            dependencies: ["HiveConduit"],
            path: "Sources/Hive/Tests/HiveConduitTests"
        ),
        .testTarget(
            name: "HiveCheckpointWaxTests",
            dependencies: ["HiveCheckpointWax"],
            path: "Sources/Hive/Tests/HiveCheckpointWaxTests"
        ),
        .testTarget(
            name: "HiveTests",
            dependencies: ["Hive"],
            path: "Sources/Hive/Tests/HiveTests"
        ),
    ]
)

