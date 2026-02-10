---
name: hive-test
description: "Scaffold a Hive test following the project's exact patterns: inline schema, graph setup, event collection, determinism assertions."
user-invocable: true
argument-hint: "[module] [feature-description]"
---

# Hive Test Scaffolding

Generate a test file following Hive's exact conventions. Every Hive test follows this structure:

## Step 1: Determine Target

Ask or infer:
- **Module**: HiveCore/Runtime, HiveCore/Schema, HiveCore/Store, HiveCore/Reducers, HiveDSL, HiveConduit, HiveMacros
- **Feature**: What behavior to test

## Step 2: Generate Test File

Place in the correct directory:
- `libs/hive/Tests/HiveCoreTests/Runtime/` — runtime, checkpoints, errors
- `libs/hive/Tests/HiveCoreTests/Reducers/` — reducer semantics
- `libs/hive/Tests/HiveCoreTests/Schema/` — channel specs, codecs
- `libs/hive/Tests/HiveCoreTests/Store/` — store operations, fingerprinting
- `libs/hive/Tests/HiveDSLTests/` — workflow compilation, patching
- `libs/hive/Tests/HiveConduitTests/` — model client integration
- `libs/hive/Tests/HiveMacrosTests/` — macro expansion assertions

## Step 3: Follow This Template

```swift
import Testing
@testable import HiveCore // or HiveDSL, HiveConduit, etc.

// MARK: - Test Helpers (only if not already in file)

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

private func makeEnvironment<Schema: HiveSchema>(context: Schema.Context) -> HiveEnvironment<Schema> {
    HiveEnvironment(
        context: context,
        clock: TestClock(),
        logger: TestLogger()
    )
}

private func collectEvents(_ stream: AsyncThrowingStream<HiveEvent, Error>) async -> [HiveEvent] {
    var events: [HiveEvent] = []
    do {
        for try await event in stream {
            events.append(event)
        }
    } catch {
        return events
    }
    return events
}

// MARK: - Schema

// Define ONLY the channels this test needs — no more
// enum Schema: HiveSchema {
//     static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
//         let key = HiveChannelKey<Schema, ValueType>(HiveChannelID("channelName"))
//         let spec = HiveChannelSpec(
//             key: key,
//             scope: .global,          // or .taskLocal
//             reducer: .lastWriteWins, // or .append(), .setUnion(), or custom
//             updatePolicy: .multi,
//             initial: { defaultValue },
//             persistence: .untracked  // or .tracked
//         )
//         return [AnyHiveChannelSpec(spec)]
//     }
// }

// MARK: - Tests

// @Test("Description of what this test verifies")
// func testFeatureBehavior() async throws {
//     // 1. Build graph
//     var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
//     builder.addNode(HiveNodeID("A")) { input in
//         HiveNodeOutput(
//             writes: [AnyHiveWrite(channelKey, value)],
//             next: .useGraphEdges
//         )
//     }
//     let graph = try builder.compile()
//
//     // 2. Create runtime and run
//     let runtime = HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))
//     let handle = try await runtime.run(threadID: "test")
//     let events = await collectEvents(handle.events)
//     let outcome = try await handle.outcome.value
//
//     // 3. Assert event ordering AND store state
//     #expect(events.contains { ... })
//     // Verify determinism: exact event sequence
// }
```

## Key Patterns

- **Inline schemas**: Each test defines its own `enum Schema: HiveSchema` with minimal channels
- **Swift Testing**: Use `import Testing`, `@Test("description")`, `#expect()`, `#require()`
- **Determinism assertions**: Always assert exact event ordering, not just presence
- **Channel keys**: `HiveChannelKey<Schema, ValueType>(HiveChannelID("name"))`
- **Writes**: `AnyHiveWrite(channelKey, value)`
- **Node output**: `HiveNodeOutput(writes:, next:)` — next is `.useGraphEdges`, `.goto([...])`, or `.end`
- **Reducers**: `.lastWriteWins`, `.append()`, `.setUnion()`, or custom `HiveReducer { current, update in ... }`
- **Checkpoint tests**: Use `InMemoryCheckpointStore` and verify round-trip
- **Interrupt tests**: Verify checkpoint ID and payload delivery on resume
- **Multi-writer tests**: Two+ nodes writing to same channel, assert reducer-applied result
