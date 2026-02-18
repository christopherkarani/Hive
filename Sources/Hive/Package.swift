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
        .library(name: "HiveRAGWax", targets: ["HiveRAGWax"]),
        .library(name: "HiveSwiftAgents", targets: ["HiveSwiftAgents"]),
        .executable(name: "HiveTinyGraphExample", targets: ["HiveTinyGraphExample"]),
    ],
    dependencies: [
        .package(url: "https://github.com/christopherkarani/Conduit", from: "0.3.1"),
        .package(
            url: "https://github.com/christopherkarani/Wax.git",
            from: "0.1.3"
        ),
    ],
    targets: [
        .target(
            name: "HiveCore",
            exclude: ["README.md"]
        ),
        .target(
            name: "HiveDSL",
            dependencies: ["HiveCore"]
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
            name: "HiveRAGWax",
            dependencies: [
                "HiveCore",
                .product(name: "Wax", package: "Wax"),
            ]
        ),
        .target(
            name: "HiveSwiftAgents",
            dependencies: [
                "HiveCore",
            ],
            exclude: ["README.md"]
        ),
        .target(
            name: "Hive",
            dependencies: [
                "HiveCore",
                "HiveDSL",
                "HiveConduit",
                "HiveCheckpointWax",
                "HiveRAGWax",
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
            name: "HiveDSLTests",
            dependencies: ["HiveDSL"]
        ),
        .testTarget(
            name: "HiveConduitTests",
            dependencies: [
                "HiveConduit",
                "HiveDSL",
            ]
        ),
        .testTarget(
            name: "HiveCheckpointWaxTests",
            dependencies: ["HiveCheckpointWax"]
        ),
        .testTarget(
            name: "HiveRAGWaxTests",
            dependencies: ["HiveRAGWax"]
        ),
        .testTarget(
            name: "HiveSwiftAgentsTests",
            dependencies: ["HiveSwiftAgents"]
        ),
        .testTarget(
            name: "HiveTests",
            dependencies: ["Hive"]
        ),
    ]
)
