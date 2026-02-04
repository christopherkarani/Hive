# HiveConduit

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
