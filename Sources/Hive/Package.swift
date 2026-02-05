// swift-tools-version: 6.2

import PackageDescription
import CompilerPluginSupport

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
        .package(
            url: "https://github.com/christopherkarani/Wax.git",
            from: "0.1.3"
        ),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
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
                "HiveDSL",
                .product(name: "Wax", package: "Wax"),
            ]
        ),
        .macro(
            name: "HiveMacrosImpl",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "HiveMacros",
            dependencies: [
                "HiveMacrosImpl",
                "HiveCore",
            ]
        ),
        .target(
            name: "Hive",
            dependencies: [
                "HiveCore",
                "HiveDSL",
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
            name: "HiveMacrosTests",
            dependencies: [
                "HiveMacros",
                "HiveMacrosImpl",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "HiveTests",
            dependencies: ["Hive"]
        ),
    ]
)
