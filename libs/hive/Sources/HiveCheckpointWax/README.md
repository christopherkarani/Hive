# HiveCheckpointWax

Wax-backed checkpoint store for Hive.

## Usage
```swift
import HiveCheckpointWax
import HiveCore
import Wax

let store = try await HiveCheckpointWaxStore<MySchema>.open(at: url)
// Or create a new store: HiveCheckpointWaxStore<MySchema>.create(at: url)

let environment = HiveEnvironment<MySchema>(
    context: appContext,
    clock: appClock,
    logger: appLogger,
    checkpointStore: AnyHiveCheckpointStore(store)
)

let options = HiveRunOptions(checkpointPolicy: .everyStep)
```

## Example
- `../../Tests/HiveCheckpointWaxTests/HiveCheckpointWaxSmokeTests.swift`
