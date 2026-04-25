// swift-tools-version: 6.2

import Foundation
import PackageDescription

let packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.7.0"),
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3"),
]

let package = Package(
    name: "Hive",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "Hive", targets: ["Hive"]),
        .library(name: "HiveCore", targets: ["HiveCore"]),
        .executable(name: "HiveTinyGraphExample", targets: ["HiveTinyGraphExample"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "HiveCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/Hive/Sources/HiveCore",
            exclude: ["README.md"]
        ),
        .target(
            name: "Hive",
            dependencies: ["HiveCore"],
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
            name: "HiveTests",
            dependencies: ["Hive"],
            path: "Sources/Hive/Tests/HiveTests"
        ),
    ]
)
