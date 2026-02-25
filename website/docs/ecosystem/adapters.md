---
sidebar_position: 1
title: Adapter Modules
description: HiveConduit, HiveCheckpointWax, and HiveRAGWax adapters.
---

# Adapter Modules

## HiveConduit

Bridges the [Conduit](https://github.com/christopherkarani/Conduit) library to `HiveModelClient`. `ConduitModelClient<Provider>` wraps any Conduit `TextGenerator`:

- Maps `HiveChatMessage` to Conduit `Message` types
- Converts `HiveToolDefinition` JSON schemas to Conduit `ToolDefinition`
- Streams tokens as `.token()` chunks, emits `.final()` on completion

```swift
import HiveConduit

let client = ConduitModelClient(provider: myProvider)
let env = HiveEnvironment<Schema>(
    context: (),
    clock: SystemClock(),
    logger: ConsoleLogger(),
    model: AnyHiveModelClient(client)
)
```

## HiveCheckpointWax

Wax-backed persistent checkpoint store. `HiveCheckpointWaxStore<Schema>` (actor):

- **save():** JSON-encodes checkpoint, stores as Wax frame with `"hive.checkpoint"` kind
- **loadLatest():** Scans frames, selects highest stepIndex for threadID
- Supports `HiveCheckpointQueryableStore` for history browsing

```swift
import HiveCheckpointWax

let checkpointStore = HiveCheckpointWaxStore<Schema>(repository: waxRepo)
let env = HiveEnvironment<Schema>(
    context: (),
    clock: SystemClock(),
    logger: ConsoleLogger(),
    checkpointStore: AnyHiveCheckpointStore(checkpointStore)
)
```

## HiveRAGWax

Wax-backed `HiveMemoryStore`. `HiveRAGWaxStore` (actor):

- **remember():** Stores text as Wax frame with `"hive.memory"` kind
- **recall():** Keyword matching against query terms, scored by match ratio
- **delete():** Removes the Wax frame

```swift
import HiveRAGWax

let ragStore = HiveRAGWaxStore(repository: waxRepo)
let env = HiveEnvironment<Schema>(
    context: (),
    clock: SystemClock(),
    logger: ConsoleLogger(),
    memoryStore: AnyHiveMemoryStore(ragStore)
)
```
