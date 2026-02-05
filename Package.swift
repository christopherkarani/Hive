// swift-tools-version: 6.2

import CompilerPluginSupport
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
        .library(name: "HiveMacros", targets: ["HiveMacros"]),
        .executable(name: "HiveTinyGraphExample", targets: ["HiveTinyGraphExample"]),
    ],
    dependencies: [
        .package(url: "https://github.com/christopherkarani/Conduit", from: "0.3.1"),
        .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.3"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
    ],
    targets: [
        .target(
            name: "HiveCore",
            path: "libs/hive/Sources/HiveCore",
            exclude: ["README.md"]
        ),
        .target(
            name: "HiveDSL",
            dependencies: ["HiveCore"],
            path: "libs/hive/Sources/HiveDSL"
        ),
        .target(
            name: "HiveConduit",
            dependencies: [
                "HiveCore",
                .product(name: "Conduit", package: "Conduit"),
            ],
            path: "libs/hive/Sources/HiveConduit",
            exclude: ["README.md"]
        ),
        .target(
            name: "HiveCheckpointWax",
            dependencies: [
                "HiveCore",
                .product(name: "Wax", package: "Wax"),
            ],
            path: "libs/hive/Sources/HiveCheckpointWax",
            exclude: ["README.md"]
        ),
        .target(
            name: "HiveRAGWax",
            dependencies: [
                "HiveDSL",
                .product(name: "Wax", package: "Wax"),
            ],
            path: "libs/hive/Sources/HiveRAGWax"
        ),
        .macro(
            name: "HiveMacrosImpl",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ],
            path: "libs/hive/Sources/HiveMacrosImpl"
        ),
        .target(
            name: "HiveMacros",
            dependencies: [
                "HiveMacrosImpl",
                "HiveCore",
            ],
            path: "libs/hive/Sources/HiveMacros"
        ),
        .target(
            name: "Hive",
            dependencies: [
                "HiveCore",
                "HiveDSL",
                "HiveConduit",
                "HiveCheckpointWax",
            ],
            path: "libs/hive/Sources/Hive",
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "HiveTinyGraphExample",
            dependencies: ["HiveCore"],
            path: "libs/hive/Examples/TinyGraph"
        ),
        .testTarget(
            name: "HiveCoreTests",
            dependencies: ["HiveCore"],
            path: "libs/hive/Tests/HiveCoreTests"
        ),
        .testTarget(
            name: "HiveDSLTests",
            dependencies: ["HiveDSL"],
            path: "libs/hive/Tests/HiveDSLTests"
        ),
        .testTarget(
            name: "HiveConduitTests",
            dependencies: [
                "HiveConduit",
                "HiveDSL",
            ],
            path: "libs/hive/Tests/HiveConduitTests"
        ),
        .testTarget(
            name: "HiveCheckpointWaxTests",
            dependencies: ["HiveCheckpointWax"],
            path: "libs/hive/Tests/HiveCheckpointWaxTests"
        ),
        .testTarget(
            name: "HiveRAGWaxTests",
            dependencies: ["HiveRAGWax"],
            path: "libs/hive/Tests/HiveRAGWaxTests"
        ),
        .testTarget(
            name: "HiveMacrosTests",
            dependencies: [
                "HiveMacros",
                "HiveMacrosImpl",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            path: "libs/hive/Tests/HiveMacrosTests"
        ),
        .testTarget(
            name: "HiveTests",
            dependencies: ["Hive"],
            path: "libs/hive/Tests/HiveTests"
        ),
    ]
)
