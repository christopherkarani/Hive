---
sidebar_position: 2
title: Store Model
description: HiveGlobalStore, HiveTaskLocalStore, HiveStoreView, and fingerprinting.
---

# Store Model

## Architecture

```
                    +---------------------+
                    |   HiveSchemaRegistry |
                    |   (channel specs)    |
                    +----------+----------+
                               |
                    +----------v----------+
                    |  HiveInitialCache    |
                    |  (default values)    |
                    +----+-------+--------+
                         |       |
          +--------------+       +-------------+
          |                                    |
+---------v---------+            +-------------v-----------+
|  HiveGlobalStore   |           |  HiveTaskLocalStore      |
|  (global channels) |           |  (task-local overlays)   |
+---------+----------+           +-------------+-----------+
          |                                    |
          +--+------+--------------------------+
             |      |
    +--------v------v--------+
    |    HiveStoreView        |
    |  (read-only merged)     |
    |  given to node closures |
    +-------------------------+
```

## HiveGlobalStore

Holds the current value for every global-scoped channel. One per thread. All tasks in a superstep see the same pre-commit snapshot.

```swift
public struct HiveGlobalStore<Schema: HiveSchema>: Sendable {
    public func get<Value: Sendable>(_ key: HiveChannelKey<Schema, Value>) throws -> Value
    mutating func set<Value: Sendable>(_ key: HiveChannelKey<Schema, Value>, _ value: Value) throws
}
```

During commit, the runtime:
1. Collects all writes, grouped by channel ID
2. Sorts writes deterministically by `(taskOrdinal, emissionIndex)`
3. Reduces using each channel's `HiveReducer`
4. Resets `.ephemeral` channels to `initial()` after all reductions

## HiveTaskLocalStore

Sparse overlay for task-local channels. Each spawned task carries its own instance.

```swift
public struct HiveTaskLocalStore<Schema: HiveSchema>: Sendable {
    public static var empty: HiveTaskLocalStore<Schema>
    public func get<Value: Sendable>(_ key: HiveChannelKey<Schema, Value>) throws -> Value?
    public mutating func set<Value: Sendable>(_ key: HiveChannelKey<Schema, Value>, _ value: Value) throws
}
```

**Key differences from global store:**
- `get` returns `Optional<Value>` (nil = use initial value)
- Only stores channels that have been explicitly written
- Scope must be `.taskLocal`

## HiveStoreView

Read-only merged view composed from global store + task-local overlay + initial cache. Every node receives one via `input.store`.

```swift
public struct HiveStoreView<Schema: HiveSchema>: Sendable {
    public func get<Value: Sendable>(_ key: HiveChannelKey<Schema, Value>) throws -> Value
}
```

**Resolution logic:**
- **Global channels:** delegate to `HiveGlobalStore.get`
- **Task-local channels:** check overlay first, fall back to `HiveInitialCache`

## HiveInitialCache

Eagerly evaluates and caches `initial()` for every channel at construction time. Provides fallback values and reset values for ephemeral channels.

## Fingerprinting

`HiveTaskLocalFingerprint` computes a SHA-256 digest of effective task-local state (overlay merged with initial values). Enables the runtime to detect identical task-local states and deduplicate frontier entries.

## Code Example

```swift
// Reading from the store in a node:
Node("worker") { input in
    let results: [String] = try input.store.get(MySchema.Channels.results)
    let item: String = try input.store.get(MySchema.Channels.item)
    return Effects {
        Set(MySchema.Channels.results, [item.uppercased()])
        End()
    }
}

// Fan-out with task-local state:
SpawnEach(["a", "b", "c"], node: "worker") { item in
    var local = HiveTaskLocalStore<Schema>.empty
    try! local.set(MySchema.Channels.item, item)
    return local
}

// Accessing final state after a run:
guard let store = await runtime.getLatestStore(threadID: threadID) else { return }
let finalResults = try store.get(MySchema.Channels.results)
```
