// swift-tools-version: 6.2

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let useLocalDeps = ProcessInfo.processInfo.environment["AISTACK_USE_LOCAL_DEPS"] == "1"

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3"),
]

if useLocalDeps {
    packageDependencies += [
        .package(path: packageRoot.appendingPathComponent("../Conduit").path),
        .package(path: packageRoot.appendingPathComponent("../Wax").path),
    ]
} else {
    packageDependencies += [
        .package(url: "https://github.com/christopherkarani/Conduit", from: "0.3.10"),
        .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.19"),
    ]
}

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
        .executable(name: "HiveTinyGraphExample", targets: ["HiveTinyGraphExample"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "HiveCore",
            path: "Sources/Hive/Sources/HiveCore",
            exclude: ["README.md"]
        ),
        .target(
            name: "HiveDSL",
            dependencies: ["HiveCore"],
            path: "Sources/Hive/Sources/HiveDSL"
        ),
        .target(
            name: "HiveConduit",
            dependencies: [
                "HiveCore",
                .product(name: "ConduitAdvanced", package: "Conduit"),
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
            name: "HiveRAGWax",
            dependencies: [
                "HiveCore",
                .product(name: "Wax", package: "Wax"),
            ],
            path: "Sources/Hive/Sources/HiveRAGWax"
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
            resources: [
                .process("Runtime/Fixtures"),
            ],
            swiftSettings: [
                .define("HIVE_V11_TRIGGERS"),
            ]
        ),
        .testTarget(
            name: "HiveDSLTests",
            dependencies: ["HiveDSL"],
            path: "Sources/Hive/Tests/HiveDSLTests"
        ),
        .testTarget(
            name: "HiveConduitTests",
            dependencies: [
                "HiveConduit",
                "HiveDSL",
                .product(name: "ConduitAdvanced", package: "Conduit"),
            ],
            path: "Sources/Hive/Tests/HiveConduitTests"
        ),
        .testTarget(
            name: "HiveCheckpointWaxTests",
            dependencies: ["HiveCheckpointWax"],
            path: "Sources/Hive/Tests/HiveCheckpointWaxTests"
        ),
        .testTarget(
            name: "HiveRAGWaxTests",
            dependencies: ["HiveRAGWax"],
            path: "Sources/Hive/Tests/HiveRAGWaxTests"
        ),
        .testTarget(
            name: "HiveTests",
            dependencies: ["Hive"],
            path: "Sources/Hive/Tests/HiveTests"
        ),
    ]
)
