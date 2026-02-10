---
name: hive
description: "Unified Hive skill — routes to test, schema, workflow, or verify based on your request."
user-invocable: true
argument-hint: "<test|schema|workflow|verify> [details...]"
---

# Hive — Unified Skill Router

Single entry point for all Hive project skills. Classify the user's request and follow the matching route below.

## Routing Rules

Parse the first argument or scan the full request for keywords:

| Keywords | Route |
|----------|-------|
| `test`, `scaffold test`, `add test`, `tests for`, `TDD`, `red phase` | **Route: test** |
| `schema`, `channel`, `channels`, `reducer`, `reducers`, `codec`, `codecs`, `HiveSchema` | **Route: schema** |
| `workflow`, `graph`, `nodes`, `edges`, `DSL`, `chain`, `branch`, `join`, `pipeline` | **Route: workflow** |
| `verify`, `check`, `compliance`, `spec`, `audit`, `HIVE_SPEC`, `normative` | **Route: verify** |

**If no keywords match or the request is ambiguous**, ask the user:

> Which Hive skill do you need?
> 1. **test** — Scaffold a test with inline schema, graph setup, and determinism assertions
> 2. **schema** — Generate a HiveSchema enum with typed channels, reducers, and codecs
> 3. **workflow** — Create a workflow using the DSL (nodes, edges, joins, branches, chains)
> 4. **verify** — Run spec compliance checks against HIVE_SPEC.md

---

## Route: test

Scaffold a Hive test following the project's exact patterns: inline schema, graph setup, event collection, determinism assertions.

### Step 1: Determine Target

Ask or infer:
- **Module**: HiveCore/Runtime, HiveCore/Schema, HiveCore/Store, HiveCore/Reducers, HiveDSL, HiveConduit, HiveMacros
- **Feature**: What behavior to test

### Step 2: Generate Test File

Place in the correct directory:
- `libs/hive/Tests/HiveCoreTests/Runtime/` — runtime, checkpoints, errors
- `libs/hive/Tests/HiveCoreTests/Reducers/` — reducer semantics
- `libs/hive/Tests/HiveCoreTests/Schema/` — channel specs, codecs
- `libs/hive/Tests/HiveCoreTests/Store/` — store operations, fingerprinting
- `libs/hive/Tests/HiveDSLTests/` — workflow compilation, patching
- `libs/hive/Tests/HiveConduitTests/` — model client integration
- `libs/hive/Tests/HiveMacrosTests/` — macro expansion assertions

### Step 3: Follow This Template

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

### Key Patterns

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

---

## Route: schema

Generate a HiveSchema enum with typed channels, reducers, and codecs. Supports both manual and @HiveSchema macro approaches.

### Step 1: Gather Channel Information

For each channel, determine:
- **Name** (string ID, used as `HiveChannelID`)
- **Value type** (e.g., `String`, `[String]`, `Int`, custom `Sendable` type)
- **Scope**: `.global` (shared across all tasks) or `.taskLocal` (per-task overlay)
- **Reducer**: How multiple writes merge
  - `.lastWriteWins` — latest value replaces previous
  - `.append()` — concatenate arrays
  - `.setUnion()` — merge sets
  - Custom: `HiveReducer { current, update in ... }`
- **Persistence**: `.tracked` (included in checkpoints) or `.untracked`
- **Codec** (optional): For checkpoint serialization. Use `HiveCodec.json()` for Codable types

### Step 2: Generate Manual Implementation

```swift
import HiveCore

enum MySchema: HiveSchema {
    // Channel keys (static accessors for type-safe reads/writes)
    static let messagesKey = HiveChannelKey<MySchema, [String]>(HiveChannelID("messages"))
    static let counterKey = HiveChannelKey<MySchema, Int>(HiveChannelID("counter"))

    static var channelSpecs: [AnyHiveChannelSpec<MySchema>] {
        let messages = HiveChannelSpec(
            key: messagesKey,
            scope: .global,
            reducer: .append(),
            updatePolicy: .multi,
            initial: { [] },
            persistence: .tracked,
            codec: HiveCodec.json()
        )
        let counter = HiveChannelSpec(
            key: counterKey,
            scope: .global,
            reducer: HiveReducer { current, update in current + update },
            updatePolicy: .multi,
            initial: { 0 },
            persistence: .tracked,
            codec: HiveCodec.json()
        )
        return [
            AnyHiveChannelSpec(messages),
            AnyHiveChannelSpec(counter),
        ]
    }

    static func mapInputs(_ input: MyInput, into writer: inout HiveInputWriter<MySchema>) {
        writer.write(messagesKey, value: input.initialMessages)
    }
}
```

### Step 3: Generate @HiveSchema Macro Version (if using macros)

```swift
import HiveCore
import HiveMacros

@HiveSchema
enum MySchema: HiveSchema {
    @Channel(scope: .global, reducer: .append(), persistence: .tracked)
    static var messages: [String] = []

    @TaskLocalChannel(reducer: .lastWriteWins, persistence: .untracked)
    static var taskStatus: String = "pending"
}
```

### Key Rules

- Channel IDs use lexicographic ordering for determinism
- All value types must be `Sendable`
- Reducers must be deterministic and associative
- Scope determines store placement: `.global` -> `HiveGlobalStore`, `.taskLocal` -> `HiveTaskLocalStore`
- Codecs are required for checkpointable channels
- `mapInputs` transforms external input into initial channel writes
- See HIVE_SPEC.md section 6 for normative requirements

---

## Route: workflow

Create a Hive workflow using the DSL — nodes, edges, joins, branches, and chains. Generates both DSL and imperative HiveGraphBuilder versions.

### Step 1: Gather Workflow Structure

Determine:
- **Nodes**: What processing steps exist? Each node reads from channels and writes results
- **Edges**: How do nodes connect? (static edges, conditional routing, fan-out)
- **Joins**: Do any nodes need to wait for multiple predecessors?
- **Branching**: Are there conditional paths based on channel state?
- **Start nodes**: Which nodes execute first?

### Step 2: Generate DSL Version

```swift
import HiveCore
import HiveDSL

// Assuming Schema is defined elsewhere
let workflow = Workflow<Schema> {
    // Start node — marked with .start()
    Node("process") { input in
        let messages = input.read(Schema.messagesKey)
        return HiveNodeOutput(
            writes: [AnyHiveWrite(Schema.messagesKey, messages + ["processed"])],
            next: .useGraphEdges
        )
    }
    .start()

    // Conditional branching via Edge with router
    Edge(from: "process") { store in
        let count = store.read(Schema.counterKey)
        if count > 5 {
            return .goto([HiveNodeID("summarize")])
        }
        return .goto([HiveNodeID("continue")])
    }

    Node("continue") { input in
        HiveNodeOutput(
            writes: [AnyHiveWrite(Schema.counterKey, 1)],
            next: .useGraphEdges
        )
    }

    Edge(from: "continue", to: "process") // loop back

    Node("summarize") { input in
        let messages = input.read(Schema.messagesKey)
        return HiveNodeOutput(
            writes: [AnyHiveWrite(Schema.summaryKey, messages.joined(separator: "\n"))],
            next: .end
        )
    }
}

let graph = try workflow.compile()
```

### Step 3: Generate Equivalent HiveGraphBuilder Version

```swift
var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("process")])

builder.addNode(HiveNodeID("process")) { input in
    let messages = input.read(Schema.messagesKey)
    return HiveNodeOutput(
        writes: [AnyHiveWrite(Schema.messagesKey, messages + ["processed"])],
        next: .useGraphEdges
    )
}

builder.addEdge(from: HiveNodeID("process")) { store in
    let count = store.read(Schema.counterKey)
    if count > 5 {
        return .goto([HiveNodeID("summarize")])
    }
    return .goto([HiveNodeID("continue")])
}

builder.addNode(HiveNodeID("continue")) { input in
    HiveNodeOutput(
        writes: [AnyHiveWrite(Schema.counterKey, 1)],
        next: .useGraphEdges
    )
}

builder.addEdge(from: HiveNodeID("continue"), to: HiveNodeID("process"))

builder.addNode(HiveNodeID("summarize")) { input in
    let messages = input.read(Schema.messagesKey)
    return HiveNodeOutput(
        writes: [AnyHiveWrite(Schema.summaryKey, messages.joined(separator: "\n"))],
        next: .end
    )
}

let graph = try builder.compile()
```

### DSL Components Reference

| Component | Purpose | Example |
|-----------|---------|---------|
| `Node("id") { ... }` | Processing step | Read channels, produce writes |
| `.start()` | Mark as entry point | `Node("init") { ... }.start()` |
| `Edge(from:to:)` | Static edge | `Edge(from: "A", to: "B")` |
| `Edge(from:) { router }` | Conditional routing | Router returns `.goto([...])` |
| `Join(sources:target:)` | Wait for all sources | Barrier synchronization |
| `Chain("A", "B", "C")` | Sequential pipeline | Sugar for A->B->C edges |
| `Branch(from:) { ... }` | Multi-way conditional | Multiple edge targets |

### Key Rules

- Routers are **synchronous**: `@Sendable (HiveStoreView<Schema>) -> HiveNext`
- Node IDs must not contain `:` or `+` (reserved for join edges)
- `.next` options: `.useGraphEdges`, `.goto([nodeIDs])`, `.end`, `.spawn(tasks)`
- Nodes marked `.start()` execute in the first superstep
- All writes are collected and committed atomically after frontier tasks complete
- See HIVE_SPEC.md section 9 for graph builder normative requirements

---

## Route: verify

Run spec compliance checks on a Hive component. Verifies code against HIVE_SPEC.md normative requirements.

### Verification Process

#### Step 1: Read Target Files
Read the file(s) or feature area to be verified.

#### Step 2: Read Relevant Spec Sections
Read HIVE_SPEC.md and identify which sections apply:
- Section 6 — Schema and Channels
- Section 7 — Store Model (Global, TaskLocal, StoreView)
- Section 8 — Reducers
- Section 9 — Graph Builder and Compilation
- Section 10 — Runtime Configuration
- Section 11 — Step Algorithm
- Section 12 — Checkpointing
- Section 13 — Interrupt and Resume
- Section 14 — Events and Streaming
- Section 15 — Error Handling
- Section 16 — Concurrency Model

#### Step 3: Check Each Requirement
For each applicable section, check against the RFC 2119 keyword classification:
- **MUST** — Absolute requirement. Violation = non-compliant.
- **SHOULD** — Recommended. Deviation requires justification.
- **MAY** — Optional. Implementation choice.

#### Step 4: Generate Compliance Report

Output format for each requirement checked:

```
[section] — [MUST/SHOULD/MAY] — [requirement text summary]
Status: PASS | DEVIATION | VIOLATION
Evidence: [line number or code reference]
Notes: [explanation if DEVIATION or VIOLATION]
```

### Critical MUST Requirements to Always Check

1. **Deterministic ordering** — Writes applied in lexicographic node ID order (section 11)
2. **Atomic commits** — All frontier task writes committed together (section 11)
3. **Checkpoint atomicity** — If save fails, step must not commit (section 12)
4. **Single-writer per thread** — Serialized execution within a thread (section 16)
5. **Reducer determinism** — Same inputs always produce same output (section 8)
6. **Channel scope** — Global vs taskLocal correctly enforced (section 6, 7)
7. **Router synchrony** — Routers must be synchronous (section 9)
8. **Node ID constraints** — No `:` or `+` in node IDs (section 9)
9. **Event ordering** — Events emitted in deterministic step order (section 14)
10. **Input mapping** — `mapInputs` applied as synthetic step 0 writes (section 10)

### Summary Format

```
## Compliance Report: [target]

Sections checked: X, Y, Z
Requirements verified: N
  PASS: N
  DEVIATION: N
  VIOLATION: N

[Details for each non-passing requirement]

Overall: COMPLIANT / NON-COMPLIANT
```
