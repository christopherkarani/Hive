# HiveCheckpointWax

[![Discord](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscord.com%2Fapi%2Fv10%2Finvites%2FNHgNh7HJ6M%3Fwith_counts%3Dtrue&query=%24.approximate_presence_count&suffix=%20online&logo=discord&label=Discord&color=5865F2)](https://discord.gg/NHgNh7HJ6M)

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

## Checkpoint Inspection
HiveCheckpointWax supports optional history and load-by-id operations:

```swift
let history = try await store.listCheckpoints(threadID: HiveThreadID("thread-1"), limit: 25)
let checkpoint = try await store.loadCheckpoint(threadID: HiveThreadID("thread-1"), id: history[0].id)
```

## Example
- `../../Tests/HiveCheckpointWaxTests/HiveCheckpointWaxSmokeTests.swift`
