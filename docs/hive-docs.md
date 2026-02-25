# Hive Documentation

**Deterministic graph runtime for agent workflows in Swift.**

Hive runs agent workflows as deterministic superstep graphs using the Bulk Synchronous Parallel (BSP) model. Same input, same output, every time — golden-testable, checkpoint-resumable, and built entirely on Swift concurrency.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Schema System](#3-schema-system)
4. [Store Model](#4-store-model)
5. [Graph Compilation](#5-graph-compilation)
6. [Runtime Engine](#6-runtime-engine)
7. [HiveDSL](#7-hivedsl)
8. [Checkpointing](#8-checkpointing)
9. [Interrupt/Resume Protocol](#9-interruptresume-protocol)
10. [Hybrid Inference](#10-hybrid-inference)
11. [Memory System](#11-memory-system)
12. [Adapter Modules](#12-adapter-modules)
13. [Data Structures](#13-data-structures)
14. [Error Handling](#14-error-handling)
15. [Testing Guide](#15-testing-guide)
16. [Examples](#16-examples)

---

## 1. Overview

Hive is the Swift equivalent of LangGraph — a deterministic graph runtime for building agent workflows. It executes workflows as **superstep graphs** where frontier nodes run concurrently, writes commit atomically, and routers schedule the next frontier.

### Why Hive?

- **Deterministic** — BSP supersteps with lexicographic ordering. Every run produces identical event traces.
- **Swift-native** — Actors, `Sendable`, `async`/`await`, result builders. No Python, no YAML, no runtime reflection.
- **Agent-ready** — Tool calling, bounded agent loops, streaming tokens, fan-out/join patterns, and hybrid inference.
- **Resumable** — Interrupt a workflow for human approval. Checkpoint state. Resume with typed payloads.

### Requirements

- Swift 6.2 toolchain
- iOS 26+ / macOS 26+

### Quick Start

```sh
swift build                              # Build all targets
swift test                               # Run all tests
swift test --filter HiveCoreTests        # Run a single test target
swift run HiveTinyGraphExample           # Run the example executable
```

### 30-Second Example

```swift
import HiveDSL

let workflow = Workflow<MySchema> {
    Node("classify") { input in
        let text = try input.store.get(MySchema.text)
        Effects {
            Set(MySchema.category, classify(text))
            UseGraphEdges()
        }
    }.start()

    Node("respond") { _ in Effects { End() } }
    Node("escalate") { _ in Effects { End() } }

    Branch(from: "classify") {
        Branch.case(name: "urgent", when: {
            (try? $0.get(MySchema.category)) == "urgent"
        }) {
            GoTo("escalate")
        }
        Branch.default { GoTo("respond") }
    }
}

let graph = try workflow.compile()
let runtime = HiveRuntime(graph: graph, environment: env)
```

---

## 2. Architecture

```
HiveCore  (zero external deps — pure Swift)
├── HiveDSL             result-builder workflow DSL
├── HiveConduit          Conduit model client adapter
├── HiveCheckpointWax    Wax-backed checkpoint store
└── HiveRAGWax           Wax-backed RAG snippets

Hive  (umbrella — re-exports Core + DSL + Conduit + CheckpointWax)
HiveMacros              @HiveSchema / @Channel / @WorkflowBlueprint
```

### Module Dependency Graph

| Module | Dependencies | Purpose |
|--------|-------------|---------|
| `HiveCore` | None | Schema, graph, runtime, store — zero external deps |
| `HiveDSL` | HiveCore | Result-builder workflow DSL |
| `HiveConduit` | HiveCore, Conduit | LLM provider adapter |
| `HiveCheckpointWax` | HiveCore, Wax | Persistent checkpoints |
| `HiveRAGWax` | HiveCore, Wax | Vector RAG persistence |
| `Hive` | All above | Umbrella re-export |

### HiveCore Internal Layout

| Directory | Responsibility |
|-----------|---------------|
| `Schema/` | Channel specs, keys, reducers, codecs, schema registry, type erasure |
| `Store/` | Global store, task-local store, store view, initial cache, fingerprinting |
| `Graph/` | Graph builder, graph description, Mermaid export, ordering, versioning |
| `Runtime/` | Superstep execution, frontier computation, event streaming, interrupts, retry |
| `Checkpointing/` | Checkpoint format and store protocol |
| `HybridInference/` | Model tool loop (ReAct), inference types |
| `Memory/` | Memory store protocol, in-memory implementation |
| `DataStructures/` | Bitset, inverted index |
| `Errors/` | Runtime errors, error descriptions |

### Key Execution Flow

```
Schema defines channels → Graph compiled from DSL/builder → Runtime executes supersteps:
  1. Frontier nodes execute concurrently (lexicographic order for determinism)
  2. Writes collected, reduced, committed atomically
  3. Routers run on fresh post-commit state
  4. Next frontier scheduled
  5. Repeat until End() or Interrupt()
```

---

## 3. Schema System

### The HiveSchema Protocol

A schema declares the typed state channels for a workflow. Every Hive graph is parameterized by a `Schema: HiveSchema`.

```swift
public protocol HiveSchema: Sendable {
    associatedtype Context: Sendable = Void
    associatedtype Input: Sendable = Void
    associatedtype InterruptPayload: Codable & Sendable = String
    associatedtype ResumePayload: Codable & Sendable = String

    static var channelSpecs: [AnyHiveChannelSpec<Self>] { get }
    static func inputWrites(_ input: Input, inputContext: HiveInputContext) throws -> [AnyHiveWrite<Self>]
}
```

| Associated Type | Purpose |
|----------------|---------|
| `Context` | User-defined context passed to every node via `HiveEnvironment` |
| `Input` | Typed input for `runtime.run()` — converted to writes before step 0 |
| `InterruptPayload` | Data type attached to interrupt requests |
| `ResumePayload` | Data type provided when resuming from an interrupt |

### Channel Specs

Each channel is declared via `HiveChannelSpec<Schema, Value>`:

```swift
public struct HiveChannelSpec<Schema: HiveSchema, Value: Sendable>: Sendable {
    public let key: HiveChannelKey<Schema, Value>
    public let scope: HiveChannelScope          // .global or .taskLocal
    public let reducer: HiveReducer<Value>      // merge strategy
    public let updatePolicy: HiveUpdatePolicy   // .single or .multi
    public let initial: @Sendable () -> Value   // default value factory
    public let codec: HiveAnyCodec<Value>?      // serialization for checkpoints
    public let persistence: HiveChannelPersistence
}
```

### Channel Keys

Type-safe references to channels:

```swift
let messages = HiveChannelKey<MySchema, [String]>(HiveChannelID("messages"))
let score = HiveChannelKey<MySchema, Int>(HiveChannelID("score"))
```

### Scopes

| Scope | Store | Visibility |
|-------|-------|-----------|
| `.global` | `HiveGlobalStore` | Shared across all tasks in a thread |
| `.taskLocal` | `HiveTaskLocalStore` | Isolated per spawned task (fan-out) |

### Persistence Modes

| Level | Checkpointed? | Reset behavior |
|-------|--------------|----------------|
| `.checkpointed` | Yes | Survives across interrupt/resume |
| `.untracked` | No | Preserved across supersteps, not saved |
| `.ephemeral` | No | Reset to `initial()` after each superstep |

### Reducers

When multiple nodes write to the same channel in one superstep, the reducer defines how writes merge:

```swift
public struct HiveReducer<Value: Sendable>: Sendable {
    public init(_ reduce: @escaping @Sendable (Value, Value) throws -> Value)
    public func reduce(current: Value, update: Value) throws -> Value
}
```

**Built-in reducers:**

| Reducer | Constraint | Behavior |
|---------|-----------|----------|
| `.lastWriteWins()` | Any | Replaces current with update |
| `.append()` | `RangeReplaceableCollection` | Appends update to current |
| `.appendNonNil()` | Optional collection | Nil-safe append |
| `.setUnion()` | `Set<Hashable>` | Union of current and update |
| `.dictionaryMerge(valueReducer:)` | `[String: V]` | Merges dictionaries, resolving conflicts via inner reducer |
| `.sum()` | `Numeric` | Adds current + update |
| `.min()` | `Comparable` | Keeps the lesser value |
| `.max()` | `Comparable` | Keeps the greater value |
| `.binaryOp(_:)` | Any | Custom binary operator |
| `HiveReducer { current, update in ... }` | Any | Fully custom reducer |

### Codecs

Channels that are checkpointed or task-local require a codec for serialization:

```swift
public protocol HiveCodec: Sendable {
    associatedtype Value: Sendable
    var id: String { get }
    func encode(_ value: Value) throws -> Data
    func decode(_ data: Data) throws -> Value
}
```

**Built-in:** `HiveJSONCodec<Value: Codable>` provides JSON serialization. Custom codecs (e.g., `StringCodec`, `StringArrayCodec`) implement the protocol directly.

**Type erasure:** `HiveAnyCodec<Value>` wraps any concrete codec.

### Type Erasure Pattern

`AnyHiveChannelSpec<Schema>` erases the `Value` generic from `HiveChannelSpec<Schema, Value>`, allowing heterogeneous channel specs in the `channelSpecs` array. It uses boxed closures (`_reduceBox`, `_initialBox`, `_encodeBox`, `_decodeBox`) to maintain type safety at runtime.

### Complete Schema Example

```swift
enum MySchema: HiveSchema {
    typealias Input = String
    typealias InterruptPayload = String
    typealias ResumePayload = String

    enum Channels {
        static let messages = HiveChannelKey<MySchema, [String]>(HiveChannelID("messages"))
        static let item = HiveChannelKey<MySchema, String>(HiveChannelID("item"))
    }

    static var channelSpecs: [AnyHiveChannelSpec<MySchema>] {
        [
            AnyHiveChannelSpec(HiveChannelSpec(
                key: Channels.messages,
                scope: .global,
                reducer: .append(),
                updatePolicy: .multi,
                initial: { [] },
                codec: HiveAnyCodec(HiveJSONCodec<[String]>()),
                persistence: .checkpointed
            )),
            AnyHiveChannelSpec(HiveChannelSpec(
                key: Channels.item,
                scope: .taskLocal,
                reducer: .lastWriteWins(),
                updatePolicy: .single,
                initial: { "" },
                codec: HiveAnyCodec(HiveJSONCodec<String>()),
                persistence: .checkpointed
            )),
        ]
    }

    static func inputWrites(
        _ input: String,
        inputContext: HiveInputContext
    ) throws -> [AnyHiveWrite<MySchema>] {
        [AnyHiveWrite(Channels.messages, [input])]
    }
}
```

### @HiveSchema Macro

The `@HiveSchema` macro eliminates boilerplate:

```swift
@HiveSchema
enum MySchema: HiveSchema {
    @Channel(reducer: "lastWriteWins()", persistence: "untracked")
    static var _answer: String = ""

    @TaskLocalChannel(reducer: "append()", persistence: "checkpointed")
    static var _logs: [String] = []
}
```

The macro generates typed `HiveChannelKey` properties, `channelSpecs`, codecs, and scope configuration.

---

## 4. Store Model

### Architecture

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

### HiveGlobalStore

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

### HiveTaskLocalStore

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

### HiveStoreView

Read-only merged view composed from global store + task-local overlay + initial cache. Every node receives one via `input.store`.

```swift
public struct HiveStoreView<Schema: HiveSchema>: Sendable {
    public func get<Value: Sendable>(_ key: HiveChannelKey<Schema, Value>) throws -> Value
}
```

**Resolution logic:**
- **Global channels:** delegate to `HiveGlobalStore.get`
- **Task-local channels:** check overlay first, fall back to `HiveInitialCache`

### HiveInitialCache

Eagerly evaluates and caches `initial()` for every channel at construction time. Provides fallback values and reset values for ephemeral channels.

### Fingerprinting

`HiveTaskLocalFingerprint` computes a SHA-256 digest of effective task-local state (overlay merged with initial values). Enables the runtime to detect identical task-local states and deduplicate frontier entries.

### Code Example

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

---

## 5. Graph Compilation

### HiveGraphBuilder

The imperative API for constructing graphs:

```swift
var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])

builder.addNode(HiveNodeID("A")) { input in
    HiveNodeOutput(
        writes: [AnyHiveWrite(key, value)],
        next: .useGraphEdges
    )
}

builder.addNode(HiveNodeID("B")) { _ in HiveNodeOutput(next: .end) }
builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))
builder.addJoinEdge(parents: [HiveNodeID("W1"), HiveNodeID("W2")], target: HiveNodeID("Gate"))
builder.addRouter(from: HiveNodeID("A")) { storeView in .nodes([HiveNodeID("B")]) }

let graph = try builder.compile()
```

### CompiledHiveGraph

The validated, immutable, executable graph:

```swift
public struct CompiledHiveGraph<Schema: HiveSchema>: Sendable {
    public let start: [HiveNodeID]
    public let staticLayersByNodeID: [HiveNodeID: Int]
    public let maxStaticDepth: Int
    // ... internal: nodes, edges, routers, join edges, version hash
}
```

### Graph Validation

`compile()` validates:
- No duplicate node IDs
- All edge targets reference existing nodes
- Start nodes exist in the graph
- No cycles in static edges (throws `staticGraphCycleDetected`)
- Router-only cycles are allowed (they're dynamic)

### Graph Description

`graphDescription()` produces a deterministic JSON representation with a SHA-256 version hash. Identical graphs always produce identical JSON — enabling golden tests.

### Mermaid Export

`HiveGraphMermaidExporter.export(description)` converts a graph description to a Mermaid flowchart for visualization:

```
flowchart TD
    Start --> WorkerA
    Start --> WorkerB
    WorkerA --> Gate
    WorkerB --> Gate
    Gate --> Finalize
```

### Static Layer Analysis

The compiler computes static layer depths via topological ordering. This enables optimizations and visualization of the graph's parallel structure.

---

## 6. Runtime Engine

### HiveRuntime Actor

`HiveRuntime<Schema>` is the central execution engine — a Swift `actor` ensuring data-race-free state management.

```swift
public actor HiveRuntime<Schema: HiveSchema>: Sendable {
    public init(graph: CompiledHiveGraph<Schema>, environment: HiveEnvironment<Schema>) throws

    public func run(threadID:, input:, options:) -> HiveRunHandle<Schema>
    public func resume(threadID:, interruptID:, payload:, options:) -> HiveRunHandle<Schema>
    public func fork(threadID:, fromCheckpointID:, into:, options:) -> HiveRunHandle<Schema>
    public func getState(threadID:) -> HiveStateSnapshot<Schema>?
    public func getLatestStore(threadID:) -> HiveGlobalStore<Schema>?
}
```

### HiveEnvironment

Dependency injection container:

```swift
public struct HiveEnvironment<Schema: HiveSchema>: Sendable {
    public let context: Schema.Context
    public let clock: any HiveClock
    public let logger: any HiveLogger
    public let model: AnyHiveModelClient?
    public let modelRouter: (any HiveModelRouter)?
    public let tools: AnyHiveToolRegistry?
    public let checkpointStore: AnyHiveCheckpointStore<Schema>?
    public let memoryStore: AnyHiveMemoryStore?
}
```

### HiveRunHandle

Every entry point returns a handle with both event stream and terminal outcome:

```swift
public struct HiveRunHandle<Schema: HiveSchema>: Sendable {
    public let runID: HiveRunID
    public let events: AsyncThrowingStream<HiveEvent, Error>
    public let outcome: Task<HiveRunOutcome<Schema>, Error>
}
```

### HiveRunOutcome

```swift
public enum HiveRunOutcome<Schema: HiveSchema>: Sendable {
    case finished(output: HiveRunOutput<Schema>, checkpointID: HiveCheckpointID?)
    case interrupted(interruption: HiveInterruption<Schema>)
    case cancelled(output:, checkpointID:)
    case outOfSteps(maxSteps:, output:, checkpointID:)
}
```

### Superstep Execution Loop (BSP Model)

Each superstep has three phases:

**Phase 1: Concurrent Node Execution**
All frontier nodes execute concurrently within a `TaskGroup`, bounded by `maxConcurrentTasks`. Each node reads from a pre-step snapshot — no node sees another's writes from the same step.

**Phase 2: Atomic Commit**
Writes are collected, ordered by `(taskOrdinal, emissionIndex)`, and reduced through each channel's reducer. Ephemeral channels reset to initial values.

**Phase 3: Frontier Scheduling**
Routers run on post-commit state. Join barriers update. The next frontier is assembled, deduplicated, and optionally filtered by trigger conditions.

### The Run Loop

```
while true:
    1. Check cancellation → return .cancelled
    2. Check frontier empty → promote deferred or return .finished
    3. Check maxSteps → return .outOfSteps
    4. Execute one superstep
    5. Save checkpoint if policy requires
    6. Emit events
    7. Check for interrupt → return .interrupted
    8. Task.yield() for cancellation observation
```

### Frontier Computation

Sources for the next frontier:
1. **Static edges** — `graph.staticEdgesByFrom[nodeID]`
2. **Routers** — dynamic routing on post-commit state
3. **Node output `next`** — `.end`, `.nodes([...])`, or `.useGraphEdges`
4. **Spawn seeds** — fan-out tasks with task-local state
5. **Join barriers** — fire when all parents complete

Seeds are deduplicated by `(nodeID, taskLocalFingerprint)`.

### Event Streaming

| Category | Events |
|----------|--------|
| Run lifecycle | `runStarted`, `runFinished`, `runInterrupted`, `runResumed`, `runCancelled` |
| Superstep | `stepStarted(stepIndex, frontierCount)`, `stepFinished(stepIndex, nextFrontierCount)` |
| Task | `taskStarted(node, taskID)`, `taskFinished(node, taskID)`, `taskFailed(node, taskID, error)` |
| Writes | `writeApplied(channelID, payloadHash)` |
| Checkpoint | `checkpointSaved(id)`, `checkpointLoaded(id)` |
| Model | `modelInvocationStarted`, `modelToken`, `modelInvocationFinished` |
| Tools | `toolInvocationStarted`, `toolInvocationFinished` |

**Streaming modes** via `HiveRunOptions`:
- `.events` — standard events only
- `.values` — full store snapshots after each step
- `.updates` — only written channels
- `.combined` — both

**Event stream views** provide typed, filtered sub-streams:

```swift
let views = HiveEventStreamViews(handle.events)
for try await step in views.steps() { /* HiveStepEvent */ }
for try await task in views.tasks() { /* HiveTaskEvent */ }
```

### Retry Policies

```swift
public enum HiveRetryPolicy: Sendable {
    case none
    case exponentialBackoff(
        initialNanoseconds: UInt64,
        factor: Double,          // >= 1.0
        maxAttempts: Int,        // >= 1
        maxNanoseconds: UInt64
    )
}
```

Delay formula: `min(maxNanoseconds, floor(initialNanoseconds * pow(factor, attempt - 1)))`

### Run Options

```swift
let options = HiveRunOptions(
    maxSteps: 50,
    maxConcurrentTasks: 4,
    checkpointPolicy: .everyStep,
    debugPayloads: true,
    deterministicTokenStreaming: true,
    eventBufferCapacity: 2048,
    streamingMode: .combined
)
```

### Determinism Guarantees

1. **Lexicographic ordering** of node execution by `HiveNodeID`
2. **Deterministic task IDs** — SHA-256 of `(runID, stepIndex, nodeID, ordinal, fingerprint)`
3. **Deterministic interrupt IDs** — SHA-256 of `"HINT1" + taskID`
4. **Deterministic checkpoint IDs** — SHA-256 of `"HCP1" + runID + stepIndex`
5. **Atomic superstep commits** — all writes apply together, sorted by `(taskOrdinal, emissionIndex)`
6. **Sorted channel iteration** — `registry.sortedChannelSpecs` ensures consistent processing
7. **Deterministic token streaming** — buffer model tokens per-task, replay in ordinal order

---

## 7. HiveDSL

### Workflow Result Builder

The top-level entry point:

```swift
public struct Workflow<Schema: HiveSchema>: Sendable {
    public init(@WorkflowBuilder<Schema> _ content: () -> AnyWorkflowComponent<Schema>)
    public func compile() throws -> CompiledHiveGraph<Schema>
}
```

### Node Definition

```swift
Node("process") { input in
    let value: String = try input.store.get(myKey)
    return Effects {
        Set(resultKey, value.uppercased())
        End()
    }
}.start()  // marks as entry point
```

### Effects DSL

Effects accumulate writes, spawn seeds, routing, and interrupt requests:

| Primitive | Purpose |
|-----------|---------|
| `Set(key, value)` | Write a value to a channel |
| `Append(key, elements: [...])` | Append to a collection channel |
| `GoTo("node")` | Route to a specific node |
| `UseGraphEdges()` | Follow statically declared edges |
| `End()` | Terminate the workflow |
| `Interrupt(payload)` | Pause execution, save checkpoint |
| `SpawnEach(items, node:, local:)` | Fan-out: spawn parallel tasks |

### Routing Primitives

**Edge** — static directed edge:
```swift
Edge("A", to: "B")
```

**Join** — barrier that waits for all parents:
```swift
Join(parents: ["worker"], to: "review")
```

**Chain** — linear sequence:
```swift
Chain {
    Chain.Link.start("A")
    Chain.Link.then("B")
    Chain.Link.then("C")
}
```

**Branch** — conditional routing:
```swift
Branch(from: "check") {
    Branch.case(name: "high", when: { view in
        (try? view.get(scoreKey)) ?? 0 >= 70
    }) {
        GoTo("pass")
    }
    Branch.default { GoTo("fail") }
}
```

**FanOut** — parallel fan-out with optional join:
```swift
FanOut(from: "dispatch", to: ["workerA", "workerB"], joinTo: "merge")
```

**SequenceEdges** — shorthand chain:
```swift
SequenceEdges("A", "B", "C")
```

### ModelTurn — LLM Integration

```swift
ModelTurn("chat", model: "gpt-4", messages: [
    HiveChatMessage(id: "u1", role: .user, content: "Weather in SF?")
])
.tools(.environment)
.agentLoop(.init(maxModelInvocations: 8, toolCallOrder: .byNameThenID))
.writes(to: answerKey)
.writesMessages(to: historyKey)
.start()
```

**Tools policy:** `.none`, `.environment` (from HiveEnvironment), `.explicit([HiveToolDefinition])`

**Mode:** `.complete` (single call) or `.agentLoop(config)` (multi-turn ReAct loop)

### Subgraph — Nested Workflows

```swift
Subgraph<ParentSchema, ChildSchema>(
    "sub",
    childGraph: childGraph,
    inputMapping: { parentStore in try parentStore.get(inputKey) },
    environmentMapping: { _ in childEnv },
    outputMapping: { _, childStore in
        [AnyHiveWrite(parentResultKey, try childStore.get(childResultKey))]
    }
)
```

### Workflow Patching

Mutate compiled graphs without full recompilation:

```swift
var patch = WorkflowPatch<Schema>()
patch.replaceNode("B") { input in Effects { End() } }
patch.insertProbe("monitor", between: "A", and: "B") { input in
    Effects { Set(probeKey, "observed"); UseGraphEdges() }
}
let result = try patch.apply(to: graph)
// result.graph — new compiled graph
// result.diff — WorkflowDiff with changes summary
```

### WorkflowBlueprint

Composable workflow fragments (SwiftUI-style protocol):

```swift
public protocol WorkflowBlueprint: WorkflowComponent {
    associatedtype Body: WorkflowComponent where Body.Schema == Schema
    @WorkflowBuilder<Schema> var body: Body { get }
}
```

### DSL Grammar Summary

```
Workflow<Schema> {
    Node("id") { input -> HiveNodeOutput }.start()
    ModelTurn("id", model:, messages:).tools(.environment).start()
    Subgraph<Parent, Child>("id", childGraph:, input:, env:, output:).start()

    Edge("from", to: "to")
    Join(parents: ["a", "b"], to: "target")
    Chain { .start("A"); .then("B"); .then("C") }
    Branch(from: "node") {
        Branch.case(name:, when:) { GoTo("x") }
        Branch.default { End() }
    }
    FanOut(from: "src", to: ["a","b"], joinTo: "merge")
    SequenceEdges("A", "B", "C")
}

// Inside nodes:
Effects {
    Set(key, value); Append(key, elements: [...]); GoTo("node")
    UseGraphEdges(); End(); Interrupt(payload)
    SpawnEach(items, node: "worker") { item in localStore }
}
```

---

## 8. Checkpointing

### Checkpoint Format

`HiveCheckpoint<Schema>` captures a complete runtime state snapshot:

| Field | Type | Purpose |
|-------|------|---------|
| `id` | `HiveCheckpointID` | Deterministic identifier |
| `threadID` | `HiveThreadID` | Thread this belongs to |
| `stepIndex` | `Int` | Superstep index at save time |
| `globalDataByChannelID` | `[String: Data]` | Encoded global store values |
| `frontier` | `[HiveCheckpointTask]` | Persisted frontier tasks |
| `joinBarrierSeenByJoinID` | `[String: [String]]` | Join barrier state |
| `interruption` | `HiveInterrupt?` | Pending interrupt |
| `channelVersionsByChannelID` | `[String: UInt64]` | Version counters |

### Store Protocol

```swift
public protocol HiveCheckpointStore: Sendable {
    associatedtype Schema: HiveSchema
    func save(_ checkpoint: HiveCheckpoint<Schema>) async throws
    func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>?
}
```

For history browsing, `HiveCheckpointQueryableStore` adds `listCheckpoints` and `loadCheckpoint`.

### Checkpoint Policy

```swift
public enum HiveCheckpointPolicy: Sendable {
    case disabled
    case everyStep
    case every(steps: Int)
    case onInterrupt
}
```

---

## 9. Interrupt/Resume Protocol

### Interrupt Flow

1. Node returns `HiveNodeOutput(interrupt: HiveInterruptRequest(payload: ...))`
2. Runtime selects the interrupt from the lowest-ordinal task (deterministic)
3. Checkpoint saved with interrupt embedded
4. Run outcome: `.interrupted(HiveInterruption(interrupt:, checkpointID:))`

### Resume Flow

1. Caller invokes `runtime.resume(threadID:, interruptID:, payload:, options:)`
2. Runtime loads latest checkpoint, verifies interrupt ID matches
3. `HiveResume<Schema>` delivered to nodes via `input.run.resume`
4. Execution continues from saved frontier

### Type System

```swift
struct HiveInterruptRequest<Schema>   // Node → runtime
struct HiveInterrupt<Schema>          // Persisted (id + payload)
struct HiveResume<Schema>             // Runtime → node (resume data)
struct HiveInterruption<Schema>       // Run outcome (interrupt + checkpointID)
```

### Code Example

```swift
// Node emits interrupt
Node("review") { _ in
    Effects { Interrupt("Approve results?") }
}

// Handle interrupt
let handle = await runtime.run(threadID: tid, input: (), options: opts)
let outcome = try await handle.outcome.value
guard case let .interrupted(interruption) = outcome else { return }

// Resume
let resumed = await runtime.resume(
    threadID: tid,
    interruptID: interruption.interrupt.id,
    payload: "approved",
    options: opts
)
let final = try await resumed.outcome.value
```

---

## 10. Hybrid Inference

### Model Client Protocol

```swift
public protocol HiveModelClient: Sendable {
    func complete(_ request: HiveChatRequest) async throws -> HiveChatResponse
    func stream(_ request: HiveChatRequest) -> AsyncThrowingStream<HiveChatStreamChunk, Error>
}
```

Streaming contract: the stream MUST emit exactly one `.final(HiveChatResponse)` as its last element.

### Inference Types

| Type | Purpose |
|------|---------|
| `HiveChatRole` | `.system`, `.user`, `.assistant`, `.tool` |
| `HiveChatMessage` | Chat message with tool calls |
| `HiveChatRequest` | Model request: model name, messages, tools |
| `HiveChatResponse` | Model response wrapping a message |
| `HiveChatStreamChunk` | `.token(String)` or `.final(HiveChatResponse)` |
| `HiveToolDefinition` | Tool exposed to models |
| `HiveToolCall` | Model-emitted tool invocation |
| `HiveToolResult` | Tool execution result |

### Model Tool Loop (ReAct)

`HiveModelToolLoop` implements a bounded ReAct loop:

1. Send conversation to model
2. If no tool calls → return final response
3. Execute tools, append results to conversation
4. Loop back (bounded by `maxModelInvocations`)

Configuration:
- `modelCallMode`: `.complete` or `.stream`
- `maxModelInvocations`: safety limit
- `toolCallOrder`: `.asEmitted` or `.byNameThenID` (deterministic)

### Tool Registry

```swift
public protocol HiveToolRegistry: Sendable {
    func listTools() -> [HiveToolDefinition]
    func invoke(_ call: HiveToolCall) async throws -> HiveToolResult
}
```

---

## 11. Memory System

### Memory Store Protocol

```swift
public protocol HiveMemoryStore: Sendable {
    func remember(namespace: [String], key: String, text: String, metadata: [String: String]) async throws
    func get(namespace: [String], key: String) async throws -> HiveMemoryItem?
    func recall(namespace: [String], query: String, limit: Int) async throws -> [HiveMemoryItem]
    func delete(namespace: [String], key: String) async throws
}
```

### HiveMemoryItem

```swift
public struct HiveMemoryItem: Sendable, Codable, Equatable {
    public let namespace: [String]
    public let key: String
    public let text: String
    public let metadata: [String: String]
    public let score: Double?
}
```

### In-Memory Implementation

`InMemoryHiveMemoryStore` (actor) provides testing/development implementation with BM25-based recall via `HiveInvertedIndex`.

---

## 12. Adapter Modules

### HiveConduit

Bridges the `Conduit` library to `HiveModelClient`. `ConduitModelClient<Provider>` wraps any Conduit `TextGenerator`:
- Maps `HiveChatMessage` to Conduit `Message` types
- Converts `HiveToolDefinition` JSON schemas to Conduit `ToolDefinition`
- Streams tokens as `.token()` chunks, emits `.final()` on completion

### HiveCheckpointWax

Wax-backed persistent checkpoint store. `HiveCheckpointWaxStore<Schema>` (actor):
- **save():** JSON-encodes checkpoint, stores as Wax frame with `"hive.checkpoint"` kind
- **loadLatest():** Scans frames, selects highest stepIndex for threadID
- Supports `HiveCheckpointQueryableStore` for history browsing

### HiveRAGWax

Wax-backed `HiveMemoryStore`. `HiveRAGWaxStore` (actor):
- **remember():** Stores text as Wax frame with `"hive.memory"` kind
- **recall():** Keyword matching against query terms, scored by match ratio
- **delete():** Removes the Wax frame

---

## 13. Data Structures

### HiveBitset

Compact, fixed-size dynamic bitset backed by `[UInt64]`:

```swift
struct HiveBitset: Sendable, Equatable {
    init(bitCapacity: Int)
    mutating func insert(_ bitIndex: Int)
    func contains(_ bitIndex: Int) -> Bool
    var isEmpty: Bool
}
```

Used by the runtime for efficient join barrier tracking.

### HiveInvertedIndex

BM25-style inverted index for in-memory text search:

```swift
struct HiveInvertedIndex: Sendable {
    mutating func upsert(docID: String, text: String)
    mutating func remove(docID: String)
    func query(terms: [String], limit: Int) -> [(docID: String, score: Double)]
    static func tokenize(_ text: String) -> [String]
}
```

BM25 parameters: k1=1.2, b=0.75. Used by `InMemoryHiveMemoryStore` for semantic recall.

---

## 14. Error Handling

### HiveRuntimeError

The primary error type covering all runtime failures:

| Category | Error Cases |
|----------|-------------|
| **Store/Channel** | `unknownChannelID`, `scopeMismatch`, `channelTypeMismatch`, `storeValueMissing`, `missingCodec` |
| **Write Policy** | `updatePolicyViolation`, `taskLocalWriteNotAllowed` |
| **Checkpoint** | `checkpointStoreMissing`, `checkpointVersionMismatch`, `checkpointDecodeFailed`, `checkpointEncodeFailed`, `checkpointCorrupt` |
| **Interrupt/Resume** | `interruptPending`, `noCheckpointToResume`, `noInterruptToResume`, `resumeInterruptMismatch` |
| **Model/Inference** | `modelClientMissing`, `modelStreamInvalid`, `toolRegistryMissing`, `modelToolLoopMaxModelInvocationsExceeded` |
| **Bounds** | `stepIndexOutOfRange`, `taskOrdinalOutOfRange` |
| **Config** | `invalidRunOptions` |
| **Internal** | `internalInvariantViolation` |

### HiveCompilationError

Graph compilation failures:
- `duplicateChannelID` — duplicate channel in schema
- `staticGraphCycleDetected` — cycle in static edges

### HiveCheckpointQueryError

- `unsupported` — store does not implement queryable protocol

---

## 15. Testing Guide

### Framework

Hive uses **Swift Testing** (`@Test`, `#expect`, `#require`), not XCTest.

### Inline Schema Pattern

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

### Test Infrastructure

Every test file declares:

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

### Event Collection

```swift
private func collectEvents(
    _ stream: AsyncThrowingStream<HiveEvent, Error>
) async -> [HiveEvent] {
    var events: [HiveEvent] = []
    do { for try await event in stream { events.append(event) } } catch {}
    return events
}
```

### Deterministic Ordering Assertions

Assert **exact sequences**, not just presence:

```swift
let taskStarts = events.compactMap { e -> HiveNodeID? in
    guard case let .taskStarted(n, _) = e.kind else { return nil }
    return n
}
#expect(taskStarts == [HiveNodeID("A"), HiveNodeID("B")])
```

### Complete Test Example

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
    let handle = await runtime.run(threadID: HiveThreadID("test"), input: (), options: HiveRunOptions())

    let eventsTask = Task { await collectEvents(handle.events) }
    let outcome = try await handle.outcome.value
    let events = await eventsTask.value

    guard case let .finished(output, _) = outcome,
          case let .fullStore(store) = output else { return }
    #expect(try store.get(valuesKey) == [1, 2, 3])  // A before B (lexicographic)
}
```

---

## 16. Examples

### Hello World

```swift
let messageKey = HiveChannelKey<Schema, String>(HiveChannelID("message"))

let graph = try Workflow<Schema> {
    Node("greet") { _ in
        Effects {
            Set(messageKey, "Hello from Hive!")
            End()
        }
    }.start()
}.compile()
```

### Branching

```swift
let graph = try Workflow<Schema> {
    Node("check") { _ in
        Effects { Set(scoreKey, 85); UseGraphEdges() }
    }.start()

    Node("pass") { _ in Effects { Set(resultKey, "passed"); End() } }
    Node("fail") { _ in Effects { Set(resultKey, "failed"); End() } }

    Branch(from: "check") {
        Branch.case(name: "high", when: { ($0.get(scoreKey) ?? 0) >= 70 }) { GoTo("pass") }
        Branch.default { GoTo("fail") }
    }
}.compile()
```

### Agent Loop with LLM

```swift
let graph = try Workflow<Schema> {
    ModelTurn("chat", model: "gpt-4", messages: [
        HiveChatMessage(id: "u1", role: .user, content: "Weather in SF?")
    ])
    .tools(.environment)
    .agentLoop(.init(maxModelInvocations: 8))
    .writes(to: answerKey)
    .start()
}.compile()
```

### Fan-Out, Join, Interrupt

```swift
let graph = try Workflow<Schema> {
    Node("dispatch") { _ in
        Effects {
            SpawnEach(["a", "b", "c"], node: "worker") { item in
                var local = HiveTaskLocalStore<Schema>.empty
                try! local.set(itemKey, item)
                return local
            }
            End()
        }
    }.start()

    Node("worker") { input in
        let item: String = try input.store.get(itemKey)
        return Effects { Append(resultsKey, elements: [item.uppercased()]); End() }
    }

    Node("review") { _ in Effects { Interrupt("Approve results?") } }
    Node("done") { _ in Effects { End() } }

    Join(parents: ["worker"], to: "review")
    Edge("review", to: "done")
}.compile()

// Run → interrupt → resume
let handle = await runtime.run(threadID: tid, input: (), options: opts)
let outcome = try await handle.outcome.value
guard case let .interrupted(interruption) = outcome else { return }

let resumed = await runtime.resume(
    threadID: tid,
    interruptID: interruption.interrupt.id,
    payload: "approved",
    options: opts
)
```

### TinyGraph Example

The executable at `Sources/Hive/Examples/TinyGraph/main.swift` demonstrates:
- Schema with custom codecs (StringCodec, StringArrayCodec)
- Fan-out via `spawn` with task-local state
- Join barrier waiting for parallel workers
- Interrupt/resume with typed payloads
- In-memory checkpoint store

```sh
swift run HiveTinyGraphExample
```

---

*Generated from the Hive codebase. See HIVE_SPEC.md for the normative specification.*
