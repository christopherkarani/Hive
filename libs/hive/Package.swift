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
        .package(path: "../../../Conduit"),
        .package(path: "../../../rag/Wax"),
    ],
    targets: [
        .target(
            name: "HiveCore",
            exclude: ["README.md"]
        ),
        .target(
            name: "HiveConduit",
            dependencies: [
                "HiveCore",
                .product(name: "Conduit", package: "Conduit"),
            ],
            exclude: ["README.md"]
        ),
        .target(
            name: "HiveCheckpointWax",
            dependencies: [
                "HiveCore",
                .product(name: "Wax", package: "Wax"),
            ],
            exclude: ["README.md"]
        ),
        .target(
            name: "Hive",
            dependencies: [
                "HiveCore",
                "HiveConduit",
                "HiveCheckpointWax",
            ],
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "HiveTinyGraphExample",
            dependencies: ["HiveCore"],
            path: "Examples/TinyGraph"
        ),
        .testTarget(
            name: "HiveCoreTests",
            dependencies: ["HiveCore"],
            swiftSettings: [
                .define("HIVE_V11_TRIGGERS"),
            ]
        ),
        .testTarget(
            name: "HiveConduitTests",
            dependencies: ["HiveConduit"]
        ),
        .testTarget(
            name: "HiveCheckpointWaxTests",
            dependencies: ["HiveCheckpointWax"]
        ),
        .testTarget(
            name: "HiveTests",
            dependencies: ["Hive"]
        ),
    ]
)
