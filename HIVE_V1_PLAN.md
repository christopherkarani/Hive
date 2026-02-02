# Hive v1 Plan (Swift port of LangGraph core runtime)

Hive is a Swift 6.2, Swift Concurrency–first, strongly typed **graph runtime** inspired by LangGraph’s “channels + reducers + supersteps” execution model. v1 targets **iOS + macOS**, runs **in-process**, and emphasizes:

- **Type safety** (compile-time safe reads/writes)
- **Deterministic execution** (reproducible results and traces)
- **Streaming** (first-class event stream for UI)
- **Checkpointing/memory** (via `HiveCheckpointWax` / Wax)
- **Pluggable inference + tools** (via `HiveConduit` + SwiftAgents-on-Hive)

This document is intentionally verbose: it is a build-spec for coding agents that need clear semantics, interfaces, and testable milestones.

**Normativity**  
`HIVE_SPEC.md` is the normative, implementation-ready source of truth. If this plan differs from `HIVE_SPEC.md`, agents MUST follow `HIVE_SPEC.md` and treat this plan as commentary/milestones only.

---

## Locked v1 decisions (do not revisit during implementation)

These are the decisions Hive v1 is built around. Coding agents must treat these as constraints.

### Platform + language

- Swift: **Swift 6.2**
- Deployment targets: **iOS 17.0**, **macOS 14.0**
- Dependency boundaries (SwiftPM):
  - `HiveCore` has no external dependencies.
  - `HiveConduit` depends on `Conduit`.
  - `HiveCheckpointWax` depends on `Wax`.
  - `SwiftAgents` depends on `HiveCore` (and may optionally depend on `HiveConduit` / `HiveCheckpointWax` for defaults).

Rationale: this keeps the concurrency and Foundation surface modern and eliminates conditional availability workarounds that slow down the port.

### Runtime semantics

- Execution model: **supersteps** (run frontier tasks concurrently → deterministically commit writes → compute next frontier).
- Determinism: **guaranteed** by stable task ordering and stable write application ordering (never depend on task completion timing).
- Routers: **synchronous only** in v1 (`(Store) -> Next`); async routers are out of scope.
- Fan-out / Send: **required** in v1; map-reduce patterns must work.
- **Send scheduling**: `spawn`/`Send` tasks always execute in the *next* superstep (never same-step).
- Durability: **step-synchronous** checkpointing in v1 (the runtime awaits save/load at step boundaries; no background flush modes).

### Reliability + control flow

- Error policy: **retry if configured, otherwise fail-fast**.
- Interrupt/resume (human-in-the-loop): **included in v1** and checkpoint-backed.

### Streaming + observability

- Streaming API: events are delivered via **`AsyncThrowingStream<HiveEvent>`** (the only event streaming surface in v1, exposed on `HiveRunHandle.events`).
- Event ordering: deterministic for non-streaming events; model stream events (invocation start/finish + tokens) are live by default and may interleave across concurrent tasks.
- Redaction: **on by default** (values are hashed/summarized; full payload requires explicit debug mode).

### Checkpointing (Wax)

- Persistence model: **full snapshot** (global store + frontier + local overlays).
- Encoding rule: **checkpointing requires codecs** for all persisted channels; missing codecs are a runtime configuration error before execution starts.
- **Untracked channels** are allowed, but are never checkpointed and are excluded from codec validation.

### SwiftAgents deliverables

- SwiftAgents (outside the Hive package) ships `HiveAgents.makeToolUsingChatAgent(...)` and the façade runtime APIs (`sendUserMessage`, `resumeToolApproval`) on top of `HiveCore`.
- The prebuilt agent graph is the default “works out of the box” path and is documented and fully covered by tests.

---

## Decision Log (v1 lock)

These choices are locked to avoid implementation churn:

- Join edges are reusable named barriers (LangGraph "waiting edge" semantics): parent tokens accumulate across steps until all parents have fired, then the barrier is consumed/reset after firing.
- Output projection is **explicit per graph**, with an **optional per-run override**. Default = full store snapshot.
- Message reducer supports **append**, **replace-by-id**, **remove-by-id**, and **remove-all**. Duplicate IDs resolve by deterministic order (last write wins).
- Untracked channels are **global-only** in v1. `.taskLocal` channels must be checkpointed.
- Streaming backpressure may drop **model token** and **debug-only** events only; lifecycle/write/checkpoint/tool events are never dropped.
- Redaction hashing uses **codec canonical bytes** if available, else **stable JSON (sorted keys, UTF-8)**, then SHA‑256.
- Hybrid routing inputs are **latencyTier**, **privacyRequired**, **tokenBudget**, **networkState**.

## 0) What “core runtime” means (v1 scope)

LangGraph’s implementation is Pregel-inspired: nodes read from channels, write to channels, and state updates merge with reducers across “supersteps”. Hive v1 ports that **core runtime shape**, but with a Swift-idiomatic design that uses:

- value types
- generics
- protocols
- explicit dependency injection
- strict concurrency (`Sendable`, cancellation)

### Included in v1

- Graph builder + compilation (`compile()` yields an immutable executable graph, including `schemaVersion`/`graphVersion` used for checkpoints)
- Schema-defined **typed channels** with reducers and initial values
- Task + step (“superstep”) executor:
  - bounded parallel node execution
  - deterministic write application
  - deterministic event ordering
  - `maxSteps` safety
  - cancellation-aware
- “Send”/fan-out style dynamic task spawning (needed for map-reduce patterns)
- Streaming events (`AsyncThrowingStream`)
- Checkpoint store protocol + `Wax` implementation
- Adapter surface for model/tool integrations (without coupling core)

### Explicitly deferred (v1.1+)

- Server / distributed runtime
- Full parity with Python/JS public APIs
- Rich channel types like user-defined barrier channels and generic consume semantics (beyond join edges / waiting edges)
- Graph visualization export (Mermaid), UI tooling
- Postgres/SQLite checkpointers

---

## 1) Principles and why they matter (deep review)

### 1.1 Type safety: embrace schema-defined channels

Python LangGraph can accept “state as dict” and reducers via runtime annotation. Hive does not replicate that dynamic style. Hive uses a **schema** that declares channels as typed keys. This yields:

- compile-time safe access (`HiveChannelKey<Schema, Value>`)
- discoverable APIs (autocomplete)
- better performance (avoid reflection and runtime key lookups)

### 1.2 Determinism is non-negotiable

If Hive can’t replay deterministically, debugging multi-step agent workflows becomes painful. Determinism must be enforced even when tasks finish out-of-order due to concurrency.

We accomplish this by splitting execution into:

- **compute phase**: run tasks concurrently, collect writes and events
- **commit phase**: apply writes in a deterministic order (stable sort), then emit events in a deterministic order (stable sort)

**Determinism boundary (v1)**  
Hive guarantees deterministic scheduling, commit order, and event ordering **given identical node outputs and identical external responses**.  
LLM/tool I/O is inherently non-deterministic; full replay determinism requires a record/replay layer (explicitly **deferred** beyond v1).

### 1.3 Explicit semantics beat implicit triggers

LangGraph internally uses channel “versions_seen” and triggers. That design is powerful, but also more dynamic and harder to make type-safe in Swift.

Hive v1 defines a clear, explicit model:

- the scheduler tracks an **active task frontier**
- edges/routers determine the next frontier
- tasks read a snapshot of global state + per-task local overrides (for `Send` fan-out)
- tasks return writes; reducers merge them into the next global snapshot

This keeps the mental model stable and testable, while still supporting the common LangGraph workflows (loops, conditional routing, map-reduce fan-out).

### 1.4 “Send” / fan-out is a core differentiator

LangGraph’s `Send(node, arg)` is essential for map-reduce (parallel calls into the same node with different task-local state). Without this, Hive would be “just a state machine”.

Therefore v1 must include a first-class task concept that supports **per-task local input**.

---

## 2) Glossary (shared language for implementers)

- **Schema**: A type that declares all channels the graph may read/write.
- **Channel**: A typed slot of state (value, reducer, initial value, and a codec used for checkpointing).
- **Reducer**: A merge function used when multiple writes target the same channel in a step.
- **Global store**: The persisted, checkpointed state snapshot for a run.
- **Local store**: Per-task overlay state used for `Send`/fan-out inputs.
- **Write**: A typed update to a channel produced by a task.
- **Task**: Execution unit = node + local store overlay + task ID.
- **Step / superstep**: One scheduler iteration; all tasks in the frontier execute, then writes commit.
- **Frontier**: The set of tasks scheduled for the next step.
- **Router**: A deterministic function that chooses next task(s) based on state.
- **Checkpoint**: Persisted snapshot (global store + frontier + metadata) used to resume.

---

## 3) LangGraph → Hive mapping (conceptual, not API parity)

| LangGraph concept | Hive concept (v1) | Why |
|---|---|---|
| `StateGraph` (builder) | `HiveGraphBuilder<Schema>` | Clear “build then compile” lifecycle |
| `Pregel` (executable) | `CompiledHiveGraph<Schema>` | Immutable graph for execution |
| state dict | `HiveGlobalStore<Schema>` | Typed channels, no dynamic dict |
| reducer annotations | `HiveReducer<Value>` on `HiveChannelSpec` | Type-safe reducer attachment |
| `Send(node, arg)` | `HiveNodeOutput.spawn` / `HiveTaskSeed(nodeID:local:)` | Type-safe map-reduce fan-out |
| streaming modes | `HiveEvent` stream | One structured event model beats many modes |
| checkpointer | `HiveCheckpointStore` + `HiveCheckpointPolicy` | Pluggable + testable |

---

## 4) Repository + module layout (for a production-quality Swift port)

Create `libs/hive` as a SwiftPM workspace root.

### 4.1 Targets

- `HiveCore`
  - no direct imports of Wax/Conduit/SwiftAgents
  - contains runtime and public API surface
- `HiveCheckpointWax`
  - depends on `HiveCore` + `Wax`
  - provides `WaxCheckpointStore`
- `HiveConduit`
  - depends on `HiveCore` + `Conduit`
  - provides `ConduitModelClient` + Conduit → Hive events mapping
- `SwiftAgents` (external package)
  - depends on `HiveCore` (optionally on `HiveConduit` / `HiveCheckpointWax` for defaults)
  - provides the prebuilt `HiveAgents` graph + facade APIs on top of Hive

### 4.2 File structure

Within `libs/hive/Sources/HiveCore/`:

- `Schema/`
  - `HiveSchema.swift`
  - `HiveChannelKey.swift`
  - `HiveChannelSpec.swift`
  - `HiveReducer.swift`
  - `HiveCodec.swift` (for checkpointing)
- `Graph/`
  - `HiveNodeID.swift`
  - `HiveTaskID.swift`
  - `HiveTask.swift`
  - `HiveGraphBuilder.swift`
  - `CompiledHiveGraph.swift`
- `Runtime/`
  - `HiveRuntime.swift`
  - `HiveRunOptions.swift`
  - `HiveRunHandle.swift`
  - `HiveRunOutcome.swift`
  - `HiveRunOutput.swift`
  - `HiveEnvironment.swift`
  - `HiveEvent.swift`
- `Checkpointing/`
  - `HiveCheckpoint.swift`
  - `HiveCheckpointStore.swift`
  - `HiveCheckpointPolicy.swift`
- `Errors/`
  - `HiveError.swift`
  - `HiveCompilationError.swift`
  - `HiveRuntimeError.swift`

Tests: `libs/hive/Tests/HiveCoreTests/` grouped similarly.

---

## 5) Core data model (type-safe channels + store)

### 5.1 Schema and channel keys

We want schema definitions that:

- are simple to write
- require minimal boilerplate
- maximize compile-time correctness

Define:

```swift
public protocol HiveSchema: Sendable {
  /// Immutable, run-scoped context exposed to every node.
  associatedtype Context: Sendable = Void

  /// Typed input payload mapped to synthetic global writes applied before the next executed step.
  associatedtype Input: Sendable = Void

  /// Payload emitted when a node interrupts execution.
  /// Must be checkpointable.
  associatedtype InterruptPayload: Codable & Sendable = String

  /// Payload provided when resuming after an interrupt.
  /// Must be checkpointable.
  associatedtype ResumePayload: Codable & Sendable = String

  /// Central declaration list used for validation and checkpoint encoding.
  static var channelSpecs: [AnyHiveChannelSpec<Self>] { get }

  /// Converts a typed run input into synthetic writes applied immediately
  /// before the next executed step of the attempt.
  static func inputWrites(_ input: Input, inputContext: HiveInputContext) throws -> [AnyHiveWrite<Self>]
}

public extension HiveSchema where Input == Void {
  static func inputWrites(_ input: Void, inputContext: HiveInputContext) throws -> [AnyHiveWrite<Self>] { [] }
}

public struct HiveChannelKey<Schema: HiveSchema, Value: Sendable>: Hashable, Sendable {
  public let id: HiveChannelID
  public init(_ id: HiveChannelID) { self.id = id }
}

public struct HiveChannelID: Hashable, Sendable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}
```

**Why string IDs?**

- stable across process runs (required for checkpointing and debugging)
- human-readable in event streams
- deterministic ordering (lexicographic)

Standardize channel IDs via namespacing: `"messages"`, `"agent.plan"`, `"internal.tasks"`.

**Key integrity rule (v1)**  
Channel IDs must be **globally unique and type-consistent** across a schema.  
Hive will maintain a runtime type registry (ID → type witness) and treat mismatches as a **runtime configuration error** (debug trap in debug builds, typed error in release).  
Keys should be declared once (as static schema members) to avoid ad-hoc ID construction.

### 5.2 Channel spec (value + reducer + initial + codec + scope)

To support `Send`/fan-out, Hive uses **channel scope**:

- `.global`: persisted and reduced into the global store
- `.taskLocal`: per-task overlay only; persisted with the frontier

Hive also uses **channel persistence**:

- `.checkpointed`: included in snapshots (requires codec)
- `.untracked`: kept in-memory only, never checkpointed

**v1 restriction**: `.taskLocal` channels must be `.checkpointed` (no untracked taskLocal).

```swift
public enum HiveChannelScope: Sendable { case global, taskLocal }
public enum HiveChannelPersistence: Sendable { case checkpointed, untracked }

public struct HiveChannelSpec<Schema: HiveSchema, Value: Sendable>: Sendable {
  public let key: HiveChannelKey<Schema, Value>
  public let scope: HiveChannelScope
  public let reducer: HiveReducer<Value>
  public let updatePolicy: HiveUpdatePolicy
  public let initial: @Sendable () -> Value
  public let codec: HiveAnyCodec<Value>?
  public let persistence: HiveChannelPersistence
}
```

**Default rule (v1)**  
`updatePolicy` defaults to `.single` unless explicitly set to `.multi` for reducer-based aggregation.

**Why include codec at the channel level?**

Checkpointing requires serialization. In Swift, not every `Sendable` is `Codable`, especially when integrating with libraries.
By making encoding explicit and per-channel, we get:

- compile-time ergonomics: `HiveCodec.codable()` helper for `Codable` values
- flexibility: custom codecs for non-codable types
- predictable persistence failures (checkpoint-backed runs fail early when codecs are missing)

### 5.3 Store design (global + local overlay)

We need two store layers:

1) `HiveGlobalStore<Schema>`: persisted, reducer-merged, checkpointed
2) `HiveTaskLocalStore<Schema>`: per-task overlay used for `Send` inputs

HiveTaskLocalStore also exposes a deterministic `fingerprint`:

- The fingerprint is computed from the **effective** task-local view:
  - for each `.taskLocal` channel, use the overlay value if present, else `initial()`
  - encode the effective value using the channel codec canonical bytes (taskLocal codecs are required in v1)
  - sort entries by `HiveChannelID.rawValue` (lexicographic)
  - build canonical bytes with length prefixes to avoid ambiguity: for each entry append `<idLen:UInt32 BE><idUTF8Bytes><valueLen:UInt32 BE><valueBytes>`
  - hash with SHA-256; the fingerprint is the 32-byte digest
- Missing overlay vs “explicitly set to initial” yields the same fingerprint (because the observable behavior is identical).
- The runtime uses this fingerprint to deduplicate converging static edges: `(nodeID, localFingerprint)`.

**Task local propagation (v1)**

- Task-local overlays do **not** propagate across static edges/routers/joins.
- Only explicit `spawn` / Send creates tasks with non-empty taskLocal overlays.

Nodes read from a composed view:

- read checks local first (if key scope is `.taskLocal`), otherwise reads global
- writes target global or taskLocal based on the channel key’s declared scope

Implementation detail (type erasure):

- internal storage will use a dictionary keyed by `HiveChannelID`
- values stored as type-erased boxes (`AnySendable`)
- typed API ensures casts are safe; still add debug traps for mismatches

This is a classic “type-safe facade over type-erased storage” approach.

### 5.4 Input/output semantics (v1)

Define exactly how a run consumes inputs and yields outputs:

- **Inputs**: external inputs are applied as **synthetic writes** immediately before the first executed step of the attempt (the first emitted `stepStarted`).
  - `run(threadID:input:...)` maps input → synthetic global writes via `Schema.inputWrites(input, inputContext: ...)` and applies them immediately before the first executed step of the attempt (the first emitted `stepStarted`).
  - Applying input writes is not a superstep and emits no `stepStarted`/`stepFinished`/`writeApplied` events.
- **Outputs**: `HiveRunHandle.outcome` yields a `HiveRunOutcome` whose `output` is computed from the graph’s output projection (or a per-run override).

---

## 6) Reducers: merge semantics + determinism

### 6.1 Reducer protocol and type erasure

```swift
public struct HiveReducer<Value: Sendable>: Sendable {
  private let _reduce: @Sendable (Value, Value) throws -> Value
  public init(_ reduce: @escaping @Sendable (Value, Value) throws -> Value) { self._reduce = reduce }
  public func reduce(current: Value, update: Value) throws -> Value { try _reduce(current, update) }
}
```

### 6.1.1 Update policy (single vs multi-write)

```swift
public enum HiveUpdatePolicy: Sendable { case single, multi }
```

- `.single` throws if more than one write targets the channel in a step.
- `.multi` applies reducer sequentially in deterministic order.

### 6.2 Standard reducers (v1 set)

- `lastWriteWins` (order is deterministic by runtime write application order)
- `append()` for arrays
- `appendNonNil()` for optionals
- `setUnion()`
- `dictionaryMerge(valueReducer:)`

### 6.3 Deterministic commit order (spec)

Within a step:

- tasks execute concurrently and produce writes
- the runtime commits writes by:
  1) use the step’s frontier order as the only task ordering key (`taskOrdinal = frontier index`), **never** task completion time and never node ID
  2) within each task, preserve write emission order
  3) group writes by channel, apply reducer sequentially in that deterministic order

This provides deterministic outputs even when task execution is concurrent.

---

## 7) Tasks, nodes, edges, routers (this is the key missing piece from the earlier draft)

### 7.1 Task = node + local input overlay

`Send(node, arg)` in LangGraph is best modeled as a task with local overlay values.

```swift
public struct HiveTaskSeed<Schema: HiveSchema>: Sendable {
  public let nodeID: HiveNodeID
  public let local: HiveTaskLocalStore<Schema>
}

/// Distinguishes graph-scheduled tasks from `spawn`/Send tasks.
public enum HiveTaskProvenance: String, Codable, Sendable { case graph, spawn }

public struct HiveTask<Schema: HiveSchema>: Sendable {
  public let id: HiveTaskID
  public let ordinal: Int
  public let provenance: HiveTaskProvenance
  public let nodeID: HiveNodeID
  public let local: HiveTaskLocalStore<Schema>
}
```

The scheduler frontier is `[HiveTask<Schema>]`, not just `[HiveNodeID]`.

### 7.2 Node signature and output

Nodes are pure with respect to Hive state: they receive an immutable snapshot view and return explicit outputs (writes + spawned tasks + routing).

```swift
public typealias HiveNode<Schema: HiveSchema> =
  @Sendable (HiveNodeInput<Schema>) async throws -> HiveNodeOutput<Schema>
```

`HiveNodeInput` contains:

- `store`: composed view of (global + local)
- `run`: run/task metadata and resume input
- `context`: run-scoped immutable context (`Schema.Context`)
- `environment`: injected dependencies (clock, logger, model client/router/hints, tools, checkpoint store)
- `emitStream`: event sink for **stream-only** events (a dedicated `HiveStreamEventKind` that maps onto `HiveEventKind.model*`/`tool*`/`customDebug`) scoped to the current task
- `emitDebug`: convenience for emitting `customDebug` events

HiveCore defines a concrete run context type:

```swift
public struct HiveRunID: Hashable, Codable, Sendable {
  public let rawValue: UUID
  public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

public struct HiveThreadID: Hashable, Codable, Sendable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct HiveRunContext<Schema: HiveSchema>: Sendable {
  public let runID: HiveRunID
  public let threadID: HiveThreadID
  public let attemptID: HiveRunAttemptID
  public let stepIndex: Int
  public let taskID: HiveTaskID
  public let resume: HiveResume<Schema>?
}
```

`HiveNodeOutput` contains:

- `writes`: `[AnyHiveWrite<Schema>]`
- `spawn`: `[HiveTaskSeed<Schema>]` (for fan-out / Send; seeds are converted into scheduled `HiveTask`s at frontier build time)
- `next`: `HiveNext` (routing override; defaults to “use graph edges”)
- `interrupt`: `HiveInterruptRequest<Schema>?` (node requests an interrupt; runtime assigns a deterministic interrupt ID)

**Why both `spawn` and `next`?**

- `spawn` is the `Send` mechanism (dynamic tasks)
- `next` is a routing override for state-machine style flows
- both are needed to cover common LangGraph patterns cleanly

### 7.3 Graph edges and routers

Graph definition supports:

- static edges: from node → node
- join edges: from `[nodeA, nodeB, ...]` → node (barrier)
- conditional routing: from node → router(store) → next node(s)

**Join semantics (v1)**  
Join edges are reusable named barriers (LangGraph "waiting edge" semantics):

- each parent contributes at most one token per barrier cycle when that parent node executes as **any task** (graph or spawn); duplicates ignored
- barrier state is `seenParents: Set<NodeID>` and is **available** iff `seenParents == parents`
- scheduling: when a commit causes a barrier to transition from not-available → available, schedule the target as a **graph task** in the next superstep (do not reset on schedule)
- consumption/reset (LangGraph parity): at the start of commit, for each executed task whose node is a join target (regardless of provenance), consume that join barrier:
  - if available, reset to empty
  - if not available, do nothing (partial progress is never cleared)
- if the target runs “early” via another edge/router while the barrier is not available, it does not reset the barrier
- barrier state is persisted in checkpoints so resume preserves join progress
- join barrier IDs are canonical: `join:<sortedParentsJoinedBy+>:<target>` (parents sorted lexicographically by `HiveNodeID.rawValue`)
- Node IDs MUST NOT contain `+` or `:` (reserved for canonical join ID formatting); compilation rejects violations.

See `HIVE_SPEC.md` §9.1 and §10.4 for the exact deterministic algorithm and ordering.

Routers are:

- synchronous pure functions of store (no side effects)
- deterministic
- evaluated **per-task** using that task’s composed view and a **fresh read** that includes that task’s own writes
- routers must not observe other tasks’ writes from the same superstep; evaluate against `preStepStore + thisTaskWrites` only
- fresh-read view construction errors are fatal: if applying `thisTaskWrites` to build the router view throws (e.g., a throwing reducer), the step fails during commit and does not commit (see `HIVE_SPEC.md` §10.4)

Routers do not perform async work in v1. Async routing is deferred to a later release.

---

## 8) Runtime semantics (the “superstep” spec)

This section is critical: it tells implementers exactly how Hive runs.

### 8.0 Runtime configuration (`HiveEnvironment` + `HiveRunOptions`)

Hive runtime configuration is split into:

- `HiveEnvironment`: injected dependencies and run-scoped context
- `HiveRunOptions`: execution controls (limits, checkpoint policy, debugging)

**Thread concurrency rule (v1)**  
Operations are **single-writer per `threadID`**. `run`, `resume`, and `applyExternalWrites` are serialized to prevent checkpoint races and “latest checkpoint” corruption.

Define these as stable public API in `HiveCore`.

#### HiveEnvironment

`HiveEnvironment` is passed to `HiveRuntime` and threaded into every `HiveNodeInput`.

- `context`: `Schema.Context`
- `clock`: deterministic clock/sleeper used for retries and timestamps
- `logger`: structured logger used for diagnostics
- `model`: optional model client (used by LLM nodes in adapter modules)
- `tools`: optional tool registry (used by tool nodes in adapter modules)
- `checkpointStore`: optional checkpoint store (Wax-backed in `HiveCheckpointWax`)

HiveCore ships type-erased wrappers so the environment can hold these as values:

- `AnyHiveModelClient`
- `AnyHiveToolRegistry`
- `AnyHiveCheckpointStore<Schema>`

This keeps node APIs non-generic while preserving testability.

#### HiveRunOptions

HiveRunOptions are immutable for a single attempt. The normative event payloads are defined in `HIVE_SPEC.md` §13 (option details, if needed, can be surfaced via event metadata).

- `maxSteps`: hard cap to prevent infinite loops (default for v1: **100**)
- `maxConcurrentTasks`: bounded concurrency for the frontier (default for v1: **8**)
- `checkpointPolicy`: when to save checkpoints (**`.everyStep`** for prebuilt SwiftAgents graphs)
- `debugPayloads`: when `true`, include full channel payloads in events (default: **false**)
- `deterministicTokenStreaming`: when `true`, buffer stream events per task and emit them after compute in deterministic taskOrdinal order (no interleaving), before `taskFinished`/`taskFailed` (default: **false**)
- `eventBufferCapacity`: bounded event buffer capacity (default: **4096**)
- `outputProjectionOverride`: optional per-run output projection override (default: **nil**)

Checkpoint save/load is step-synchronous in v1 (the runtime awaits store I/O at step boundaries; no background flush).

Concrete types defined in HiveCore:

```swift
public enum HiveCheckpointPolicy: Sendable {
  case disabled
  case everyStep
  case every(steps: Int)
  case onInterrupt
}

public struct HiveRunOptions: Sendable {
  public let maxSteps: Int
  public let maxConcurrentTasks: Int
  public let checkpointPolicy: HiveCheckpointPolicy
  public let debugPayloads: Bool
  public let deterministicTokenStreaming: Bool
  public let eventBufferCapacity: Int
  public let outputProjectionOverride: HiveOutputProjection?
}

public protocol HiveClock: Sendable {
  /// Monotonic time source used for backoff and durations.
  func nowNanoseconds() -> UInt64
  func sleep(nanoseconds: UInt64) async throws
}

public protocol HiveLogger: Sendable {
  func debug(_ message: String, metadata: [String: String])
  func info(_ message: String, metadata: [String: String])
  func error(_ message: String, metadata: [String: String])
}

public struct HiveEnvironment<Schema: HiveSchema>: Sendable {
  public let context: Schema.Context
  public let clock: any HiveClock
  public let logger: any HiveLogger
  public let model: AnyHiveModelClient?
  public let modelRouter: (any HiveModelRouter)?
  public let inferenceHints: HiveInferenceHints?
  public let tools: AnyHiveToolRegistry?
  public let checkpointStore: AnyHiveCheckpointStore<Schema>?
}
```

**Hybrid inference rule (v1)**  
If `modelRouter` is provided, **prebuilt nodes** use it to pick the model client per request (e.g., on-device vs cloud), passing `inferenceHints` when available. Otherwise they use `model`.

HiveCore includes:

- `SystemClock` backed by `ContinuousClock`/`Task.sleep`
- `TestClock`/`ManualClock` for deterministic retry/backoff tests
- `NoopLogger` and `PrintLogger` implementations

**Backpressure note (v1)**  
`eventBufferCapacity` bounds the run’s event stream buffer. When `deterministicTokenStreaming == true`, it also bounds each task’s buffered stream-event list (per `HIVE_SPEC.md` §13.4). This is intentionally simple for v1; if we need separate caps later, we can add `streamEventBufferCapacityPerTask` in v1.1+.

### 8.1 Inputs and identifiers

Each run has:

- `HiveRunID` (UUID) — **stable across resumes**
- `HiveRunAttemptID` (UUID) — new ID per execution attempt (initial run + each resume)
- `HiveThreadID` (string/UUID) — “conversation/session”
- `stepIndex` (Int)

`HiveInputContext` is passed to `Schema.inputWrites(...)` to make input mapping deterministic and testable:

```swift
public struct HiveInputContext: Sendable {
  public let threadID: HiveThreadID
  public let runID: HiveRunID
  /// The next step index to execute for this attempt (the step index of the first `stepStarted` emitted by this attempt).
  public let stepIndex: Int
}
```

Each task has:

- `HiveTaskID` derived deterministically from `(runID, stepIndex, nodeID, ordinal, localFingerprint)`
  - “ordinal” is stable by ordering in the frontier
  - `localFingerprint` is the SHA-256 digest described in the store section (effective task-local view)
  - v1 encoding (normative per `HIVE_SPEC.md`): `taskID = sha256(runUUIDBytes || UInt32BE(stepIndex) || 0x00 || nodeIDUTF8 || 0x00 || UInt32BE(ordinal) || localFingerprint32)`, exposed as a lowercase hex string

### 8.1.1 Input mapping and output extraction

Inputs are mapped to synthetic global writes via `Schema.inputWrites(input, inputContext: ...)` and applied immediately before the first executed step of the attempt (the first emitted `stepStarted`).

Outputs are produced as a `HiveRunOutput` using the graph’s compiled `outputProjection` (or a per-run override).

### 8.2 Step algorithm (pseudocode)

This is illustrative only. The normative runtime algorithm is `HIVE_SPEC.md` §10.0–§10.4.

High-level outline:

1. Emit `runStarted` (once).
2. Resolve baseline thread state:
   - Use in-memory state if present; otherwise load latest checkpoint if configured; otherwise initialize fresh.
   - If the baseline frontier is empty, seed from `start` in builder order.
3. For `run(threadID:input:...)`, map `input` to synthetic global writes using `Schema.inputWrites(input, inputContext: ...)` and apply them before the first `stepStarted` (not a superstep; emits no step events).
4. Execute steps until completion, interrupt, cancellation, or out-of-steps:
   - Track `stepsExecutedThisAttempt` separately from the persisted `stepIndex` (see `HIVE_SPEC.md` §10.4).
   - If `stepsExecutedThisAttempt == maxSteps` and the frontier is non-empty, stop without executing another step and return `.outOfSteps`.
   - Emit `stepStarted(stepIndex: S, ...)`, then task lifecycle + optional stream events.
   - Commit using the deterministic ordering and validation rules in `HIVE_SPEC.md` §10.4 (writes, routers/fresh-read, join scheduling/consumption, dedupe, next frontier build).
   - Save checkpoints only at step boundaries per policy; a required save failure aborts commit.
   - Emit `stepFinished`, then eventually the terminal run event.
5. `applyExternalWrites(...)` is a special case: it commits exactly one synthetic empty-frontier step and ignores `maxSteps` (see `HIVE_SPEC.md` §10.0).

### 8.3 Cancellation semantics

- If the parent task is cancelled:
  - cancel all running node tasks
  - emit `runCancelled`
  - return `.cancelled(lastCheckpointOrSnapshot)`

### 8.4 Error semantics

Hive v1 error semantics:

- Each node has a `HiveRetryPolicy` (default: `.none`).
- On failure, Hive retries that node according to its policy using a deterministic schedule.
- If retries are exhausted, the run fails immediately (fail-fast).

HiveCore defines:

```swift
public enum HiveRetryPolicy: Sendable {
  case none
  case exponentialBackoff(
    initialNanoseconds: UInt64,
    factor: Double,
    maxAttempts: Int,
    maxNanoseconds: UInt64
  )
}
```

Rules:

- No jitter in v1 (jitter is non-deterministic and is deferred).
- Retries are safe only for nodes that are idempotent or otherwise retry-tolerant.
- Prebuilt SwiftAgents graph nodes set retry policies on model/tool execution nodes; pure routing/state nodes use `.none`.

Retry determinism requirements:

- retries must not break determinism (retry scheduling and backoff should be deterministic in tests using an injected clock/sleeper)

### 8.5 Interrupt + resume semantics (human-in-the-loop)

Hive v1 includes interrupt/resume as a first-class control-flow mechanism and persists interruptions in checkpoints.

#### Core types

HiveCore defines interruption types that are checkpointable and schema-typed:

```swift
public struct HiveInterruptID: Hashable, Codable, Sendable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Node output requests an interrupt; runtime assigns an ID deterministically.
public struct HiveInterruptRequest<Schema: HiveSchema>: Codable, Sendable {
  public let payload: Schema.InterruptPayload
}

public struct HiveInterrupt<Schema: HiveSchema>: Codable, Sendable {
  public let id: HiveInterruptID
  public let payload: Schema.InterruptPayload
}

public struct HiveResume<Schema: HiveSchema>: Codable, Sendable {
  public let interruptID: HiveInterruptID
  public let payload: Schema.ResumePayload
}

public struct HiveInterruption<Schema: HiveSchema>: Codable, Sendable {
  public let interrupt: HiveInterrupt<Schema>
  public let checkpointID: HiveCheckpointID
}
```

**How a node interrupts**

- A node sets `output.interrupt = HiveInterruptRequest(payload:)` (runtime assigns `HiveInterrupt.id`).
- The interrupt payload is `Schema.InterruptPayload` (`Codable & Sendable`) and is always persisted.

**What the runtime does on interrupt**

- Hive completes the current step’s **commit phase** deterministically (all task writes are committed in stable task order and the next frontier is computed/persisted).
- Hive emits:
  - `runInterrupted` (includes interrupt id + payload summary)
  - `checkpointSaved` (checkpointing is enabled for the prebuilt SwiftAgents graphs and can be enabled for any graph)
- Hive saves a checkpoint snapshot immediately after commit.
- Hive returns `.interrupted(HiveInterruption)` containing the interrupt and the checkpoint reference.

**How a run resumes**

- Resume input is `Schema.ResumePayload` (`Codable & Sendable`).
- The runtime API provides `resume(threadID:interruptID:payload:)` that:
  - loads the latest checkpoint for `threadID`
  - validates that the stored interruption id matches `interruptID`
  - sets `HiveRunContext.resume = HiveResume(interruptID:payload:)` for the resumed run
  - continues execution from the persisted frontier

Resume is visible to nodes via `HiveRunContext` for the first step of the resume attempt only (see `HIVE_SPEC.md` §12.3). Graph logic decides how to apply the resume payload (for SwiftAgents tool approval, the `tools` node consumes it to proceed/abort).

**Deterministic rule**

- If multiple tasks attempt to interrupt in the same step, Hive selects the interrupt from the earliest task in deterministic task order and ignores later interrupts (while still committing deterministic writes).
- Interrupt selection occurs **after all tasks in the step complete**; v1 does not early-abort a step to preserve determinism.
- Interrupt IDs are runtime-assigned deterministically from the selected task ID (see `HIVE_SPEC.md` §12.2).

---

## 9) Streaming events (structured observability)

### 9.1 Single event model over “stream modes”

LangGraph has multiple “stream modes”. In Swift, a single strongly typed event stream is clearer.

Define `HiveEvent` with stable IDs and payloads that are safe for UI:

- run lifecycle
- step lifecycle
- task/node lifecycle
- write application (channel + metadata)
- checkpoint saved/loaded
- adapter events (model tokens, tool calls)

HiveCore defines an event model with stable IDs and deterministic ordering for non-streaming events (run/step/task lifecycle, writes, checkpoints, interrupts). Model stream events (invocation start/finish + tokens) may be delivered live for UI responsiveness.

```swift
public struct HiveEventID: Hashable, Codable, Sendable {
  public let runID: HiveRunID
  public let attemptID: HiveRunAttemptID
  public let eventIndex: UInt64       // 0-based, monotonically increasing per attempt
  public let stepIndex: Int?          // nil for run-level events
  public let taskOrdinal: Int?        // nil unless task-scoped
}

public enum HiveEventKind: Sendable {
  case runStarted(threadID: HiveThreadID)
  case runFinished
  case runInterrupted(interruptID: HiveInterruptID)
  case runResumed(interruptID: HiveInterruptID)
  case runCancelled

  case stepStarted(stepIndex: Int, frontierCount: Int)
  case stepFinished(stepIndex: Int, nextFrontierCount: Int)

  case taskStarted(node: HiveNodeID, taskID: HiveTaskID)
  case taskFinished(node: HiveNodeID, taskID: HiveTaskID)
  case taskFailed(node: HiveNodeID, taskID: HiveTaskID, errorDescription: String)

  case writeApplied(channelID: HiveChannelID, payloadHash: String)
  case checkpointSaved(checkpointID: HiveCheckpointID)
  case checkpointLoaded(checkpointID: HiveCheckpointID)

  // Adapter-facing events (emitted by HiveConduit / SwiftAgents nodes).
  case modelInvocationStarted(model: String)
  case modelToken(text: String)
  case modelInvocationFinished

  case toolInvocationStarted(name: String)
  case toolInvocationFinished(name: String, success: Bool)

  /// Debug-only diagnostic emitted when droppable events are dropped/coalesced due to backpressure.
  case streamBackpressure(droppedModelTokenEvents: Int, droppedDebugEvents: Int)

  /// Debug-only custom event emitted by nodes.
  case customDebug(name: String)
}

public struct HiveEvent: Sendable {
  public let id: HiveEventID
  public let kind: HiveEventKind
  public let metadata: [String: String]
}
```

**Node/adaptor stream emission (v1)**  
Nodes and adapters MUST NOT emit arbitrary `HiveEventKind`. They emit stream-only events via `HiveNodeInput.emitStream(kind:metadata:)` using:

```swift
public enum HiveStreamEventKind: Sendable {
  case modelInvocationStarted(model: String)
  case modelToken(text: String)
  case modelInvocationFinished
  case toolInvocationStarted(name: String)
  case toolInvocationFinished(name: String, success: Bool)
  case customDebug(name: String)
}
```

The runtime maps `HiveStreamEventKind` onto the corresponding `HiveEventKind` cases (see `HIVE_SPEC.md` §10.3 and §13).

Rules:

- Exact delivery classes (deterministic vs stream), required sequencing constraints, and backpressure rules are defined in `HIVE_SPEC.md` §13.
- `errorDescription` is a redacted description suitable for logs/UI. Full error details are included only when debug mode is enabled.

### 9.2 Deterministic event ordering

See `HIVE_SPEC.md` §13.2 for the normative deterministic event sequencing and ordering constraints.

### 9.3 Redaction and hashing

Do not dump full channel values by default.

Hive emits:

- channel ID + stable hash (when encodable) + lightweight previews
- full values only when `HiveRunOptions.debugPayloads == true`

**Hashing rule (v1)**  
Use codec-provided canonical bytes when available; otherwise use stable JSON with sorted keys and UTF-8 encoding, then SHA-256, to ensure cross-run determinism.

### 9.4 Streaming backpressure (v1)

Hive must implement a **bounded** event buffer (default capacity: **4096** events) to avoid unbounded memory growth in UI apps.

When the buffer is full, Hive applies a deterministic overflow policy:

- droppable events may be **dropped** and/or **coalesced** (token events may be merged into larger chunks)
- non-droppable events are **never dropped**; if the buffer contains only non-droppable events, producers may suspend until space is available
- emit a debug-only `streamBackpressure(droppedModelTokenEvents:droppedDebugEvents:)` diagnostic when any droppable events are dropped/coalesced

**Droppable events (v1)**: `modelToken` and debug-only diagnostics.  
**Non-droppable events (v1)**: run/step/task lifecycle, writes, checkpoints, interrupts, `modelInvocationStarted`/`modelInvocationFinished`, tool invocation start/finish.

---

## 10) Checkpointing and Wax integration (deepened)

### 10.1 What to persist (v1)

Persist a full snapshot:

- `threadID`, `runID`, `stepIndex`
- `graphVersion`, `schemaVersion` (fail-fast on mismatch in v1)
- `globalStore` values (encoded per channel via codec)
- `frontier` tasks (node IDs + provenance + local overlays for task-local channels, encoded per codec)
- join barrier state (per join edge ID: parents seen since last consume)
- **Untracked channels are excluded** from snapshots by definition

**Step index rule (v1)**  
`checkpoint.stepIndex` is the **next step index to execute on resume** (i.e., the state is “at the boundary before stepIndex”).  
A checkpoint saved after committing step `N` uses `stepIndex = N + 1` and persists the computed `nextFrontier`.

HiveCore defines checkpoint types and a store protocol:

```swift
public struct HiveCheckpointID: Hashable, Codable, Sendable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct HiveCheckpointTask: Codable, Sendable {
  public let provenance: HiveTaskProvenance
  public let nodeID: HiveNodeID
  public let localFingerprint: Data
  public let localDataByChannelID: [String: Data]
}

public struct HiveCheckpoint<Schema: HiveSchema>: Codable, Sendable {
  public let id: HiveCheckpointID
  public let threadID: HiveThreadID
  public let runID: HiveRunID
  public let stepIndex: Int

  /// Used to fail-fast when resuming a run after a schema/graph change.
  public let schemaVersion: String
  public let graphVersion: String

  /// Encoded values for all `.global` channels (keyed by channel id string).
  public let globalDataByChannelID: [String: Data]

  /// The persisted frontier.
  public let frontier: [HiveCheckpointTask]

  /// Join barrier progress keyed by canonical join barrier ID (see Join semantics).
  /// Each `seenParents` list must be sorted lexicographically for stable encoding.
  public let joinBarrierSeenByJoinID: [String: [String]]

  /// Present only when the run is paused.
  public let interruption: HiveInterrupt<Schema>?
}

public protocol HiveCheckpointStore: Sendable {
  associatedtype Schema: HiveSchema
  func save(_ checkpoint: HiveCheckpoint<Schema>) async throws
  func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>?
}

public struct AnyHiveCheckpointStore<Schema: HiveSchema>: Sendable {
  private let _save: @Sendable (HiveCheckpoint<Schema>) async throws -> Void
  private let _loadLatest: @Sendable (HiveThreadID) async throws -> HiveCheckpoint<Schema>?

  public init<S: HiveCheckpointStore>(_ store: S) where S.Schema == Schema {
    self._save = store.save
    self._loadLatest = store.loadLatest
  }

  public func save(_ checkpoint: HiveCheckpoint<Schema>) async throws { try await _save(checkpoint) }
  public func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>? { try await _loadLatest(threadID) }
}
```

### 10.1.1 Versioning (v1)

Hive uses checkpoint version fields to fail fast when resuming after incompatible changes:

- `schemaVersion`: SHA-256 of a canonical schema manifest derived from `Schema.channelSpecs` (channel IDs, scope, persistence, updatePolicy, codec ID)
  - v1 compatibility contract is **codec ID**, not Swift type reflection.
  - `valueTypeID` (e.g. `String(reflecting:)`) is diagnostic-only and MUST NOT participate in the `schemaVersion` hash.
- `graphVersion`: SHA-256 of a canonical compiled graph manifest including ordered static edges and ordered join edges (since builder order affects runtime)

Note: Router closures cannot be hashed. If you change router logic without changing graph structure, the `graphVersion` may remain unchanged. If your app requires strict compatibility checks, provide an explicit `graphVersion` override on graph compilation (v1 optional).
In v1, expose this as `HiveGraphBuilder.compile(graphVersionOverride: String? = nil)` (or equivalent) so apps can bump versions deliberately.

**Why snapshot over delta log?**

- simplest to implement and test
- fastest resume path (no replay)
- best fit for mobile where you want reliability over minimal storage

Delta logs/time-travel are deferred until after v1 ships.

### 10.2 Codec strategy

Define:

- `HiveCodec<Value>` for `Codable` values
- `HiveAnyCodec<Value>` type-erased wrapper stored in channel specs

Encoding rules (v1):

- If checkpointing is enabled, all `.global` channels have a codec.
- All `.taskLocal` channels have a codec (task locals are persisted in the frontier).
- Channels marked `.untracked` are **not** required to have codecs.

If codecs are missing and checkpointing is enabled:

- Graph compilation succeeds (the graph is still valid for in-memory runs).
- The runtime fails before the first step with a clear configuration error that lists missing codec channel IDs.

### 10.3 Wax storage layout (conceptual)

Wax implementation details depend on Wax APIs; implementers map the layout below to Wax collections/keys.

- Keyspace: `hive/checkpoints/<threadID>/latest`
- Store:
  - metadata record (JSON)
  - per-channel blobs (Data)
  - frontier tasks list (JSON + per-task local blobs)

Add version fields (`schemaVersion`, `graphVersion`) to allow migrations and fail-fast resume.

### 10.4 State inspection + external updates (v1)

Hive v1 includes state inspection and external state mutation APIs because they are required for real apps (debugging, UI rendering, and “inject user message then continue” flows).

HiveRuntime exposes:

- `getLatestCheckpoint(threadID:)` → returns the latest checkpoint (or nil)
- `getLatestStore(threadID:)` → returns a decoded `HiveGlobalStore<Schema>` snapshot
- `applyExternalWrites(threadID:writes:options:)` → applies a set of global writes as a synthetic committed step and returns a `HiveRunHandle` (events + awaited outcome)

Rules:

- External writes use the same reducer semantics as normal node writes.
- External writes are committed as their own “synthetic step” (empty frontier) and emit events (so the UI can stay consistent).
- If a checkpoint store is configured, external writes are persisted immediately regardless of checkpoint policy.

See `HIVE_SPEC.md` §10.0 for the exact `HiveRuntime` public API and external write semantics.

---

## 11) Conduit + SwiftAgents integration (adapter boundaries)

### 11.1 Dependency policy (v1)

- `HiveCore` has no external dependencies.
- The Hive package ships optional adapters:
  - `HiveConduit` (depends on `Conduit`)
  - `HiveCheckpointWax` (depends on `Wax`)
- `SwiftAgents` depends on `HiveCore` and may optionally depend on the Hive adapters for defaults.
- All third-party integrations live in adapter modules; HiveCore only defines canonical contracts.

HiveCore defines minimal, stable protocols and value types used by adapters and convenience nodes:

#### Canonical chat + tool types (HiveCore)

```swift
public enum HiveChatRole: String, Codable, Sendable { case system, user, assistant, tool }

public enum HiveChatMessageOp: String, Codable, Sendable { case remove, removeAll }

public struct HiveChatMessage: Codable, Sendable {
  public let id: String
  public let role: HiveChatRole
  public let content: String
  public let name: String?
  public let toolCallID: String?
  public let toolCalls: [HiveToolCall]
  public let op: HiveChatMessageOp?
}

public struct HiveToolDefinition: Codable, Sendable {
  public let name: String
  public let description: String
  public let parametersJSONSchema: String
}

public struct HiveToolCall: Codable, Sendable {
  public let id: String
  public let name: String
  public let argumentsJSON: String
}

public struct HiveToolResult: Codable, Sendable {
  public let toolCallID: String
  public let content: String
}
```

#### Model client (HiveCore)

```swift
public struct HiveChatRequest: Codable, Sendable {
  public let model: String
  public let messages: [HiveChatMessage]
  public let tools: [HiveToolDefinition]
}

public struct HiveChatResponse: Codable, Sendable {
  public let message: HiveChatMessage
}

public enum HiveChatStreamChunk: Sendable {
  case token(String)
  case final(HiveChatResponse)
}

public protocol HiveModelClient: Sendable {
  func complete(_ request: HiveChatRequest) async throws -> HiveChatResponse
  func stream(_ request: HiveChatRequest) -> AsyncThrowingStream<HiveChatStreamChunk, Error>
}

public struct AnyHiveModelClient: HiveModelClient, Sendable {
  private let _complete: @Sendable (HiveChatRequest) async throws -> HiveChatResponse
  private let _stream: @Sendable (HiveChatRequest) -> AsyncThrowingStream<HiveChatStreamChunk, Error>

  public init<M: HiveModelClient>(_ model: M) {
    self._complete = model.complete
    self._stream = model.stream
  }

  public func complete(_ request: HiveChatRequest) async throws -> HiveChatResponse { try await _complete(request) }
  public func stream(_ request: HiveChatRequest) -> AsyncThrowingStream<HiveChatStreamChunk, Error> { _stream(request) }
}

public protocol HiveModelRouter: Sendable {
  func route(_ request: HiveChatRequest, hints: HiveInferenceHints?) -> AnyHiveModelClient
}

public enum HiveLatencyTier: String, Sendable { case interactive, background }
public enum HiveNetworkState: String, Sendable { case offline, online, metered }

public struct HiveInferenceHints: Sendable {
  public let latencyTier: HiveLatencyTier
  public let privacyRequired: Bool
  public let tokenBudget: Int?
  public let networkState: HiveNetworkState
}
```

#### Tool registry (HiveCore)

```swift
public protocol HiveToolRegistry: Sendable {
  func listTools() -> [HiveToolDefinition]
  func invoke(_ call: HiveToolCall) async throws -> HiveToolResult
}

public struct AnyHiveToolRegistry: HiveToolRegistry, Sendable {
  private let _listTools: @Sendable () -> [HiveToolDefinition]
  private let _invoke: @Sendable (HiveToolCall) async throws -> HiveToolResult
  public init<T: HiveToolRegistry>(_ tools: T) {
    self._listTools = tools.listTools
    self._invoke = tools.invoke
  }
  public func listTools() -> [HiveToolDefinition] { _listTools() }
  public func invoke(_ call: HiveToolCall) async throws -> HiveToolResult { try await _invoke(call) }
}
```

Adapters convert provider-specific message/tool representations into these canonical Hive types.

### 11.2 Conduit adapter (HiveConduit)

Responsibilities:

- implement `ConduitModelClient: HiveModelClient`
- map Conduit streaming chunks into `HiveChatStreamChunk` and emit `HiveEvent.modelToken(...)`
- emit model invocation start/finish events (including model name and usage metadata)
- keep prompt templates and provider-specific request knobs inside `HiveConduit`

### 11.3 SwiftAgents adapter (SwiftAgents on Hive)

Responsibilities:

- adapt SwiftAgents tool definitions into `HiveToolRegistry` (tool name, args JSON, result content)
- expose a typed `HiveAgents` façade that produces ready-to-run graphs and safe defaults
- emit tool invocation events (`toolInvocationStarted` / `toolInvocationFinished`) with tool name + call id metadata

#### Prebuilt SwiftAgents graph (v1 deliverable)

SwiftAgents ships a prebuilt graph that is the default entry point for apps:

`HiveAgents.makeToolUsingChatAgent(...) -> CompiledHiveGraph<HiveAgents.Schema>`

SwiftAgents also ships a façade API that makes the prebuilt graph easy to use in apps (no manual wiring):

```swift
public struct HiveAgentsRuntime: Sendable {
  public let threadID: HiveThreadID
  public let runtime: HiveRuntime<HiveAgents.Schema>
  public let options: HiveRunOptions

  public func sendUserMessage(_ text: String) async -> HiveRunHandle<HiveAgents.Schema>
  public func resumeToolApproval(
    interruptID: HiveInterruptID,
    decision: HiveAgents.ToolApprovalDecision
  ) async -> HiveRunHandle<HiveAgents.Schema>
}

public enum HiveAgentsToolApprovalPolicy: Sendable {
  case never
  case always
  case allowList(Set<String>) // tool names
}
```

Rules:

- `sendUserMessage` calls `HiveRuntime.run(threadID:input:options:)` with `input = text`.
- `resumeToolApproval` calls `HiveRuntime.resume(threadID:interruptID:payload:options:)` with `payload = .toolApproval(decision: decision)`.
- The façade uses Wax checkpointing by default and sets `checkpointPolicy = .everyStep`.

##### HiveAgents.Schema (channels)

All values are persisted and checkpointed (global scope), except where noted.

- `messages: [HiveChatMessage]` — reducer: LangGraph-parity `add_messages` behavior (append/replace/remove/remove-all) via `HiveChatMessage.op`; see `HIVE_SPEC.md` §16.3
- `pendingToolCalls: [HiveToolCall]` — reducer: last-write-wins
- `finalAnswer: String?` — reducer: last-write-wins
- `llmInputMessages: [HiveChatMessage]?` — **global + untracked** (ephemeral preModel output, cleared after model)
- `currentToolCall: HiveToolCall?` — **taskLocal scope** (used when spawning tool tasks)

HiveAgents.Schema locks its interrupt/resume payloads to support tool approval:

- `InterruptPayload = HiveAgents.Interrupt` (Codable enum)
- `ResumePayload = HiveAgents.Resume` (Codable enum)

SwiftAgents defines:

```swift
public enum HiveAgents {
  public static let removeAllMessagesID = "__remove_all__"

  public enum ToolApprovalDecision: String, Codable, Sendable { case approved, rejected }

  public enum Interrupt: Codable, Sendable {
    case toolApprovalRequired(toolCalls: [HiveToolCall])
  }

  public enum Resume: Codable, Sendable {
    case toolApproval(decision: ToolApprovalDecision)
  }
}
```

HiveAgents also defines a run-scoped context that the prebuilt graph reads:

```swift
public struct HiveAgentsContext: Sendable {
  public let modelName: String
  public let tools: [HiveToolDefinition]
  public let toolApprovalPolicy: HiveAgentsToolApprovalPolicy
  public let compactionPolicy: HiveCompactionPolicy?
  public let tokenizer: (any HiveTokenizer)?
}
```

HiveAgents.Schema sets `Context = HiveAgentsContext`.

##### Context management + compaction (v1)

- `messages` uses a reducer that supports **append**, **replace-by-id**, **remove-by-id**, and **remove-all** (for trimming/compaction workflows).
- `HiveChatMessage.id` is required for replacement/removal; the prebuilt HiveAgents graph assigns deterministic IDs (no UUID-based IDs; see `HIVE_SPEC.md` §16.2–§16.4).
- `preModel` may emit `llmInputMessages` (global + untracked) to avoid mutating `messages` while still controlling model context.
- A `HiveTokenizer` + `HiveCompactionPolicy` are provided by SwiftAgents to support token-budgeted trimming (no summarization in v1).

```swift
public protocol HiveTokenizer: Sendable {
  func countTokens(_ messages: [HiveChatMessage]) -> Int
}

public struct HiveCompactionPolicy: Sendable {
  public let maxTokens: Int
  public let preserveLastMessages: Int
}
```

##### Node set (fixed)

- `model`: calls `HiveModelClient` with `messages` + `context.tools`; writes:
  - if `llmInputMessages` is present, use it as the model input and then clear it
  - append assistant message to `messages`
  - set `pendingToolCalls` from parsed tool calls
  - set `finalAnswer` when no tool calls exist and assistant message is final
- `preModel`: compaction/trimming hook (built-in compaction node unless the caller provides a custom `preModel:`)
- `routeAfterModel`: synchronous router:
  - if `pendingToolCalls` is empty → `.end`
  - else → `tools`
- `tools`: spawns one `toolExecute` task per `pendingToolCalls` item:
  - sort tool calls by `(name, id)` before spawning (deterministic)
  - enforce `context.toolApprovalPolicy`:
    - when approval is required and no approval resume payload is present, interrupt with `HiveAgents.Interrupt.toolApprovalRequired(toolCalls:)`
    - when resumed with `.toolApproval(decision: .approved)`, proceed with spawning tool tasks
    - when resumed with `.toolApproval(decision: .rejected)`, clear `pendingToolCalls`, append a system message noting the rejection, and route back to `model`
  - each spawned task sets taskLocal `currentToolCall`
  - clear `pendingToolCalls` in global store (set to `[]`)
- `toolExecute`: runs a single tool call using `HiveToolRegistry`:
  - emits tool invocation start/finish events
  - appends a `HiveChatMessage(role: .tool, toolCallID: currentToolCall.id, content: result.content, toolCalls: [])` to `messages`
  - static edge to `model`
- `postModel` (optional): validation/guardrails hook

##### Graph wiring

- `.start -> preModel -> model` (preModel always exists in the prebuilt HiveAgents graph)
- `model -> postModel? -> routeAfterModel`
- `routeAfterModel -> tools` (when tool calls exist)
- `tools` spawns `toolExecute` tasks
- `toolExecute -> model` (converges and deduplicates to a single `model` task in the next step because it has an empty local overlay)

##### Interrupt/resume integration

HiveAgents uses interrupts to implement human-in-the-loop workflows:

- tool approval: `tools` interrupts before executing tools when an approval policy is enabled. The interrupt payload includes the tool calls that are about to run. Resume payload provides the approval decision.

Checkpointing is enabled and saved every step so the UI can resume instantly after an interrupt.

HiveAgents handles user chat turns via schema input writes:

- `HiveAgents.Schema.Input == String`
- `HiveAgents.Schema.inputWrites(_ text: String, inputContext: HiveInputContext)` appends a `.user` message to `messages`, clears `finalAnswer`, and assigns deterministic message IDs (see `HIVE_SPEC.md` §16.2).
- `HiveAgentsRuntime.sendUserMessage(_:)` calls `HiveRuntime.run(threadID:input:options:)` and relies on the input mapping above

---

## 12) TDD plan (Swift Testing Framework) — expanded

We build Hive by writing tests first. The runtime is stateful, concurrent, and event-driven; tests must pin down semantics.

### 12.1 Test suite structure

- `ReducerTests`
- `StoreTests`
- `GraphCompilationTests`
- `RuntimeStepTests`
- `RuntimeDeterminismTests`
- `SendAndFanOutTests`
- `CheckpointTests`
- `AdapterContractTests` (protocol-level, no network)

### 12.2 Canonical v1 tests (must-have)

**Reducers**

- last-write-wins respects task ordering, not completion time
- single-write policy throws on multiple writes in a step
- append reducer merges arrays deterministically
- dictionary merge reducer composes correctly

**Store**

- reading any declared channel returns a value (store eagerly initializes all channels to their initial values)
- local overlay shadows global for task-local keys
- typed writes can’t target wrong key type (compile-time)

**Compilation**

- duplicate node IDs rejected
- edge to unknown node rejected
- missing entry (`start` edge) rejected
- router returns unknown node rejected at runtime with clear error (compile-time can’t always catch)
- join edge requires all parents to contribute before triggering

**Runtime**

- linear flow: start → A → end
- conditional routing: A → (B or end)
- loop with maxSteps: A → A
- task failures: fail-fast returns error + emits correct events
- cancellation: cancel mid-step cancels node tasks and returns cancelled result
- interrupt: node interrupts, run returns `.interrupted`, checkpoint is saved
- resume: resuming with payload continues deterministically and reaches expected final state

**Send / fan-out**

- router spawns N tasks with distinct local inputs
- all tasks run concurrently
- global aggregator channel reduces N results deterministically

**Checkpoint**

- checkpoint after each step restores global store + frontier exactly
- resume continues deterministically to same final store
- missing codec causes clear error when checkpointing enabled
- untracked channels are excluded from checkpoint data
- external writes: `applyExternalWrites` commits reducer-correct updates and persists a checkpoint

**HiveAgents (SwiftAgents prebuilt)**

- `sendUserMessage` appends a user message then runs to completion
- preModel compaction can emit `llmInputMessages` without mutating `messages`
- tool call loop: model produces tool calls → tools execute → model continues → final answer
- tool approval: tools node interrupts → resume with approved executes tools → resume with rejected routes back to model
- streaming emits token + tool invocation events in deterministic order
- message reducer supports remove-by-id and remove-all without breaking determinism

### 12.3 Golden traces

For a small set of graphs, store a **codable** “golden” event trace (serialized form) and final store summary, and compare in tests.  
Either make `HiveEventKind` codable or map events to a stable, codable trace record. Normalize `attemptID` if present.

---

## 13) Implementation roadmap (phased, but more granular than the initial draft)

### Phase 0 — Scaffold (1–2 days)

- [ ] Add `libs/hive` SwiftPM package with targets described above
- [ ] Add Swift Testing test targets
- [ ] Add minimal docs: `README.md` for Hive and module READMEs
- [ ] Set deployment targets to iOS 17.0 and macOS 14.0 in `Package.swift`

### Phase 1 — Schema + reducers + codecs (core foundations)

- [ ] Implement `HiveChannelID`, `HiveChannelKey<Schema, Value>`
- [ ] Implement `HiveReducer<Value>` + standard reducers
- [ ] Implement `HiveUpdatePolicy` (single vs multi-write)
- [ ] Implement `HiveCodec` and type-erased `HiveAnyCodec`
- [ ] Implement `HiveChannelSpec` + `AnyHiveChannelSpec` type erasure
- [ ] Implement `HiveChannelPersistence` (checkpointed vs untracked)
- [ ] Implement schema validation:
  - [ ] unique channel IDs
  - [ ] channel scope sanity (e.g., reserved internal IDs)
- [ ] Tests: reducers + codec roundtrips

### Phase 2 — Stores (global + local)

- [ ] Implement type-erased storage backend
- [ ] Implement `HiveGlobalStore<Schema>`
- [ ] Implement `HiveTaskLocalStore<Schema>`
- [ ] Implement composed read view used by nodes
- [ ] Implement `AnyHiveWrite<Schema>` + typed factory helpers
- [ ] Tests: overlay behavior + typed access

### Phase 3 — Graph builder + compilation

- [ ] Implement `HiveNodeID`, `HiveTaskID`
- [ ] Implement `HiveGraphBuilder<Schema>`
  - [ ] add nodes
  - [ ] add edges
  - [ ] add join edges (barrier)
  - [ ] add routers
  - [ ] define entry/finish semantics (`start`/`end`)
  - [ ] define output channel set (optional)
- [ ] Implement `compile()` returning `CompiledHiveGraph`
- [ ] Implement canonical hashing for `schemaVersion`/`graphVersion` (HSV1/HGV1) exactly per `HIVE_SPEC.md` §14.3 (codecID-only for schema)
- [ ] Tests: compile errors and diagnostics

### Phase 4 — Runtime engine + events (vertical slice)

- [ ] Define `HiveEvent` model + stable ordering rules
- [ ] Define `HiveStreamEventKind` and enforce stream-only emission via `HiveNodeInput.emitStream(...)` (map to `HiveEventKind`)
- [ ] Define runtime configuration types: `HiveRunOptions`, `HiveCheckpointPolicy`, `HiveRetryPolicy`, `HiveEnvironment`, `HiveModelRouter`, `HiveInferenceHints`
- [ ] Define run lifecycle types: `HiveRunHandle`, `HiveRunOutcome`, `HiveRunOutput`, `HiveInterruption`, `HiveResume`, runtime error types
- [ ] Implement `HiveRuntime` actor:
  - [ ] run loop with frontier + steps + commit
  - [ ] bounded concurrency for tasks
  - [ ] deterministic commit + event emission
  - [ ] canonical hashing for redacted payloads
  - [ ] interrupt handling + resume entry point
  - [ ] retry execution using `HiveRetryPolicy` + `HiveClock`
- [ ] Tests: linear run + determinism under randomized task completion

### Phase 5 — Send / fan-out (map-reduce)

- [ ] Implement `HiveTask` frontier model and `spawn` outputs
- [ ] Implement router APIs that can return:
  - [ ] a single next node
  - [ ] multiple tasks with local overlays
- [ ] Tests: map-reduce example (classic “subjects → jokes” pattern)

### Phase 6 — Checkpointing integration + Wax implementation

- [ ] Define `HiveCheckpoint` encoding format
- [ ] Implement checkpoint policies (`disabled`, `everyStep`, `every(n)`, `onInterrupt`)
- [ ] Implement `WaxCheckpointStore` in `HiveCheckpointWax`
- [ ] Integrate runtime save/load/resume + interruption persistence
- [ ] Implement state inspection + external writes (`getLatestCheckpoint`, `getLatestStore`, `applyExternalWrites`)
- [ ] Ensure untracked channels are excluded from snapshot data
- [ ] Add deterministic encode-failure errors and selection rules:
  - [ ] `HiveRuntimeError.checkpointEncodeFailed(...)` (abort commit deterministically)
  - [ ] `HiveRuntimeError.taskLocalFingerprintEncodeFailed(...)` (fail fast deterministically)
- [ ] Tests: save/load + resume determinism + encode-failure determinism

### Phase 7 — Adapters (Conduit + SwiftAgents on Hive)

- [ ] Implement `HiveModelClient` + `AnyHiveModelClient` in `HiveCore`
- [ ] Implement `HiveToolRegistry` + `AnyHiveToolRegistry` in `HiveCore`
- [ ] Implement `ConduitModelClient` in `HiveConduit`
- [ ] Implement `SwiftAgentsToolRegistry` adapter in SwiftAgents (Hive integration)
- [ ] Build prebuilt SwiftAgents graph (`HiveAgents.makeToolUsingChatAgent`) in the SwiftAgents repo
- [ ] Add pre/post model hooks + compaction policy support
- [ ] Build façade runtime API (`HiveAgentsRuntime.sendUserMessage`, `resumeToolApproval`)
- [ ] Add tool approval interrupt/resume coverage tests
- [ ] Add end-to-end example app snippet/docs
- [ ] Tests: adapter contract tests with mocks

### Phase 8 — Docs + examples + hardening

- [ ] “Getting Started” + “Design rationale” docs
- [ ] Example graphs:
  - [ ] workflow graph
  - [ ] agent loop graph with tools
  - [ ] checkpoint resume demo
- [ ] Performance profiling + optimizations where needed
- [ ] API review for v1 stability

---

## 14) Definition of Done (v1)

Hive v1 is “done” when:

- `HiveCore` supports:
  - typed channels + reducers + initial values
  - graph compile + validation
  - runtime with deterministic steps + streaming events
  - Send/fan-out tasks with local overlays
  - join edges (barrier) and untracked channels
- `HiveCheckpointWax`:
  - saves/loads checkpoints
  - resume produces identical results to uninterrupted run
- `HiveConduit` + SwiftAgents (Hive integration):
  - at least one working, documented “agent loop” example
- Tests cover the core semantics and determinism

---

## 15) Agent checklist (must pass before calling v1 “done”)

Use this checklist as the final review gate. If any item fails, v1 is not shippable.

### Determinism + correctness

- [ ] Running the same graph twice with the same inputs produces identical final stores and identical event traces (golden-trace tests).
- [ ] Task ordering never depends on task completion timing (add a test that randomizes task completion order).
- [ ] Reducer merge order is stable and documented; multi-writer conflicts resolve deterministically.
- [ ] Frontier deduplication by `(nodeID, localFingerprint)` works and is covered by tests (converging edges schedule the node once).

### Concurrency + safety

- [ ] All public types are `Sendable` (or explicitly `@unchecked Sendable` with justification).
- [ ] Runtime cancellation cleanly cancels in-flight node tasks and returns a `.cancelled` result with a usable snapshot.
- [ ] No shared mutable state is accessible to node code (nodes receive immutable snapshots + produce explicit writes).

### Checkpointing + resume

- [ ] Checkpointing persists and restores: global store + frontier + interruption state.
- [ ] Missing codecs fail before step 0 with a clear error listing missing channel IDs.
- [ ] Untracked channels are excluded from checkpoint data.
- [ ] Interrupt/resume persists interruption state and resumes from the correct frontier.
- [ ] External state updates (`applyExternalWrites`) produce correct reducer results and emit consistent events.

### SwiftAgents “batteries included” UX

- [ ] `HiveAgents.makeToolUsingChatAgent` exists, compiles, and is documented with a minimal working example.
- [ ] `HiveAgentsRuntime.sendUserMessage(_:)` exists and uses `HiveRuntime.run(threadID:input:options:)` (via `HiveAgents.Schema.inputWrites`) to produce an assistant response.
- [ ] preModel compaction + `llmInputMessages` path works end-to-end.
- [ ] Tool approval interrupt/resume path works end-to-end:
  - interrupt lists tool calls
  - resume with approval decision continues execution deterministically
- [ ] Streaming emits:
  - model token events
  - tool invocation start/finish events
  - step/task lifecycle events for UI

### Build + tests

- [ ] `swift test` passes for `HiveCore`, `HiveCheckpointWax`, `HiveConduit`; SwiftAgents tests pass in the SwiftAgents repo.
- [ ] Public API is reviewed for ergonomics (naming, defaults, minimal footguns).
