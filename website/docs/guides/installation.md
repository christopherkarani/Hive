---
title: Installation
description: Add Hive to a Swift package.
---

# Installation

Hive requires Swift 6.2.

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Hive.git", from: "1.0.0")
]
```

Use the umbrella product or the core product directly:

```swift
.product(name: "Hive", package: "Hive")
.product(name: "HiveCore", package: "Hive")
```

`Hive` re-exports `HiveCore`; both expose the same graph runtime API.

## Verify

```sh
swift build --target HiveCore
swift build --target Hive
swift run HiveTinyGraphExample
swift test --filter HiveCoreTests
```
