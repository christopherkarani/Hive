---
sidebar_position: 4
title: Memory System
description: HiveMemoryStore protocol, HiveMemoryItem, and in-memory BM25 implementation.
---

# Memory System

## Memory Store Protocol

```swift
public protocol HiveMemoryStore: Sendable {
    func remember(namespace: [String], key: String, text: String, metadata: [String: String]) async throws
    func get(namespace: [String], key: String) async throws -> HiveMemoryItem?
    func recall(namespace: [String], query: String, limit: Int) async throws -> [HiveMemoryItem]
    func delete(namespace: [String], key: String) async throws
}
```

## HiveMemoryItem

```swift
public struct HiveMemoryItem: Sendable, Codable, Equatable {
    public let namespace: [String]
    public let key: String
    public let text: String
    public let metadata: [String: String]
    public let score: Double?
}
```

## In-Memory Implementation

`InMemoryHiveMemoryStore` (actor) provides a testing/development implementation with BM25-based recall via `HiveInvertedIndex`.

### Usage

```swift
let memoryStore = InMemoryHiveMemoryStore()

// Store a memory
try await memoryStore.remember(
    namespace: ["user", "preferences"],
    key: "theme",
    text: "User prefers dark mode with orange accents",
    metadata: ["source": "settings"]
)

// Recall by query
let results = try await memoryStore.recall(
    namespace: ["user", "preferences"],
    query: "color theme",
    limit: 5
)
```

### Integration

Provide a memory store via `HiveEnvironment`:

```swift
let env = HiveEnvironment<Schema>(
    context: (),
    clock: SystemClock(),
    logger: ConsoleLogger(),
    memoryStore: AnyHiveMemoryStore(InMemoryHiveMemoryStore())
)
```

Nodes can access memory through the environment for long-term knowledge retrieval.

## Persistent Implementation

See [HiveRAGWax](/docs/ecosystem/adapters#hiveragwax) for the Wax-backed persistent memory store with keyword-based recall.
