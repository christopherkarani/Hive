---
sidebar_position: 3
title: Testing Guide
description: Swift Testing patterns, inline schemas, event collection, and determinism assertions.
---

# Testing Guide

## Framework

Hive uses **Swift Testing** (`@Test`, `#expect`, `#require`), not XCTest. Tests are `async throws` free functions.

## Inline Schema Pattern

Each test defines a minimal schema scoped to its needs:

```swift
@Test("My test")
func myTest() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
            return [AnyHiveChannelSpec(HiveChannelSpec(
                key: key, scope: .global, reducer: .lastWriteWins(),
                initial: { 0 }, persistence: .untracked
            ))]
        }
    }
    let valueKey = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
    // ... build graph, run, assert
}
```

## Test Infrastructure

Every test file declares minimal test doubles:

```swift
private struct TestClock: HiveClock {
    func nowNanoseconds() -> UInt64 { 0 }
    func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

private struct TestLogger: HiveLogger {
    func debug(_ message: String, metadata: [String: String]) {}
    func info(_ message: String, metadata: [String: String]) {}
    func error(_ message: String, metadata: [String: String]) {}
}
```

## Event Collection

Drain the runtime's event stream into an array:

```swift
private func collectEvents(
    _ stream: AsyncThrowingStream<HiveEvent, Error>
) async -> [HiveEvent] {
    var events: [HiveEvent] = []
    do { for try await event in stream { events.append(event) } } catch {}
    return events
}
```

## Deterministic Ordering Assertions

Assert **exact sequences**, not just presence:

```swift
let taskStarts = events.compactMap { e -> HiveNodeID? in
    guard case let .taskStarted(n, _) = e.kind else { return nil }
    return n
}
#expect(taskStarts == [HiveNodeID("A"), HiveNodeID("B")])
```

## Complete Test Example

```swift
@Test("Two parallel writers produce deterministic append order")
func twoParallelWriters() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, [Int]>(HiveChannelID("values"))
            return [AnyHiveChannelSpec(HiveChannelSpec(
                key: key, scope: .global, reducer: .append(),
                updatePolicy: .multi, initial: { [] }, persistence: .untracked
            ))]
        }
    }

    let valuesKey = HiveChannelKey<Schema, [Int]>(HiveChannelID("values"))
    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A"), HiveNodeID("B")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(valuesKey, [1, 2])])
    }
    builder.addNode(HiveNodeID("B")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(valuesKey, [3])])
    }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: env)
    let handle = await runtime.run(
        threadID: HiveThreadID("test"), input: (), options: HiveRunOptions()
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    let outcome = try await handle.outcome.value
    let events = await eventsTask.value

    guard case let .finished(output, _) = outcome,
          case let .fullStore(store) = output else { return }
    #expect(try store.get(valuesKey) == [1, 2, 3])  // A before B (lexicographic)
}
```

## Key Principles

1. **Inline schemas** — Keep each test self-contained with only the channels it needs
2. **Build imperatively** — Use `HiveGraphBuilder<Schema>` for test clarity
3. **Collect all events** — Drain the `AsyncThrowingStream` before asserting
4. **Assert exact ordering** — Verify sequence, not just presence
5. **Checkpoint round-trips** — Test save/load cycles for resumable workflows
