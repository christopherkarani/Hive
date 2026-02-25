---
sidebar_position: 1
title: Installation
description: Swift Package Manager setup and platform requirements.
---

# Installation

## Requirements

- **Swift 6.2** toolchain
- **iOS 26+** / **macOS 26+**

## Swift Package Manager

Add Hive to your `Package.swift`:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Hive.git", from: "1.0.0")
]
```

Then add the product to your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "Hive", package: "Hive")
    ]
)
```

## Choosing a Product

| Product | What you get | External deps |
|---------|-------------|---------------|
| `HiveCore` | Schema, graph, runtime, store | None |
| `HiveDSL` | Core + result-builder workflow DSL | None |
| `HiveConduit` | Core + Conduit LLM adapter | Conduit |
| `HiveCheckpointWax` | Core + persistent checkpoints | Wax |
| `HiveRAGWax` | Core + vector RAG | Wax |
| `Hive` | Everything (umbrella) | Conduit, Wax |

For zero external dependencies, use `HiveCore` alone:

```swift
.product(name: "HiveCore", package: "Hive")
```

For batteries-included, use the `Hive` umbrella:

```swift
.product(name: "Hive", package: "Hive")
```

## Building

```bash
swift build                              # Build all targets
swift test                               # Run all tests
swift test --filter HiveCoreTests        # Run a single test target
swift run HiveTinyGraphExample           # Run the example
```

## Xcode

Open the package directory in Xcode. The SPM package will resolve automatically. Select the `HiveTinyGraphExample` scheme to run the example.
