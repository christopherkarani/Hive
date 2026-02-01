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
        .library(name: "HiveSwiftAgents", targets: ["HiveSwiftAgents"]),
    ],
    dependencies: [
        .package(path: "../../../Conduit"),
        .package(path: "../../../rag/Wax"),
        .package(path: "../../../SwiftAgents"),
    ],
    targets: [
        .target(
            name: "HiveCore"
        ),
        .target(
            name: "HiveConduit",
            dependencies: [
                "HiveCore",
                .product(name: "Conduit", package: "Conduit"),
            ]
        ),
        .target(
            name: "HiveCheckpointWax",
            dependencies: [
                "HiveCore",
                .product(name: "Wax", package: "Wax"),
            ]
        ),
        .target(
            name: "HiveSwiftAgents",
            dependencies: [
                "HiveCore",
                .product(name: "SwiftAgents", package: "SwiftAgents"),
            ]
        ),
        .target(
            name: "Hive",
            dependencies: [
                "HiveCore",
                "HiveConduit",
                "HiveCheckpointWax",
                "HiveSwiftAgents",
            ]
        ),
        .testTarget(
            name: "HiveCoreTests",
            dependencies: ["HiveCore"]
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
            name: "HiveSwiftAgentsTests",
            dependencies: ["HiveSwiftAgents"]
        ),
        .testTarget(
            name: "HiveTests",
            dependencies: ["Hive"]
        ),
    ]
)
