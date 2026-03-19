# HiveConduit

[![Discord](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscord.com%2Fapi%2Fv10%2Finvites%2FNHgNh7HJ6M%3Fwith_counts%3Dtrue&query=%24.approximate_presence_count&suffix=%20online&logo=discord&label=Discord&color=5865F2)](https://discord.gg/NHgNh7HJ6M)

Conduit-backed `HiveModelClient` adapter.

## Usage
```swift
import Conduit
import HiveConduit
import HiveCore

let client = ConduitModelClient(
    provider: provider,
    config: .default,
    modelIDForName: { modelName in
        // Map Hive model names to your Conduit provider's model ID type.
        try mapModelName(modelName)
    }
)

let environment = HiveEnvironment<MySchema>(
    context: appContext,
    clock: appClock,
    logger: appLogger,
    model: AnyHiveModelClient(client)
)
```

## Example
- `../../Tests/HiveConduitTests/ConduitModelClientStreamingTests.swift`
