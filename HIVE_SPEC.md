# Hive v1 Spec (Swift port of LangGraph core runtime)

This document is the implementation-ready spec for Hive v1. It is derived from `HIVE_V1_PLAN.md` and locks all v1 decisions required to start coding.

---

## 0) Normativity and keywords

- This spec is **normative**. If `HIVE_V1_PLAN.md` differs, **this spec wins**.
- Keywords are used in the RFC 2119 sense: **MUST**, **MUST NOT**, **SHOULD**, **MAY**.
- Any behavior that impacts observable results (store contents, checkpoints, events, ordering, hashes) MUST be fully deterministic under the conditions described in this spec.

---

## 1) Scope and goals

Hive is a Swift 6.2, Swift Concurrency-first, deterministic graph runtime inspired by LangGraph's channel/reducer/superstep model. v1 targets iOS 17 and macOS 14, runs in-process, and is optimized for hybrid on-device + cloud inference with a focus on on-device(iOS/MacOS)

### Goals

- Strongly typed channels and store access
- Deterministic execution and event ordering (with live model-token streaming)
- First-class streaming (AsyncThrowingStream)
- Full snapshot checkpointing (Wax)
- Fan-out / Send for map-reduce workflows
- Human-in-the-loop interrupts and resume

### Non-goals (v1)

- Distributed runtime / server orchestration
- Full API parity with Python Langgraph Implementation
- Async routers
- Postgres/SQLite checkpointers

---

## 2) Locked v1 decisions

- Swift 6.2, iOS 17 / macOS 14
- Dependency boundaries (SwiftPM):
  - `HiveCore` has no external dependencies.
  - `HiveConduit` depends on `Conduit`.
  - `HiveCheckpointWax` depends on `Wax`.
  - `SwiftAgents` depends on `HiveCore` (and may optionally depend on `HiveConduit` / `HiveCheckpointWax` for defaults).
- Deterministic superstep execution (BSP)
- Routers are synchronous only
- Send tasks execute in the next superstep
- Checkpointing is step-synchronous in v1 (the runtime awaits save/load at step boundaries; store APIs may be async)
- Untracked channels are global-only; taskLocal must be checkpointed
- Backpressure drops only model token + debug events
- Token streaming is live by default; deterministic buffering can be enabled per run for golden tests

---

## 3) Decision log (v1)

- Join edges are reusable named barriers (LangGraph "waiting edge" semantics): parent tokens accumulate across steps until all parents have fired, then the barrier is consumed/reset after firing.
- Output projection is explicit per graph, with optional per-run override. Default is full store snapshot.
- Message reducer supports append, replace-by-id, remove-by-id, remove-all. Duplicate IDs resolve by deterministic order.
- Redaction hashing uses codec canonical bytes if available; otherwise stable JSON (sorted keys, UTF-8) and SHA-256.
- Hybrid routing hints are: latencyTier, privacyRequired, tokenBudget, networkState.

---

## 4) Terminology

- Schema: declares channels and types
- Channel: typed slot of state with reducer, initial value, codec
- Reducer: merge function for multiple writes in a step
- Global store: persisted state snapshot
- Task local store: per-task overlay used for Send
- Task seed: (node + task-local overlay) produced by nodes/routers/edges during commit
- Task: scheduled execution unit = (id + node + task-local overlay + frontier ordinal)
- Frontier: tasks scheduled for a step
- Superstep: one full execution cycle (run tasks, commit writes, compute next frontier)
- Router: deterministic selection of next nodes
- Checkpoint: persisted snapshot (global store + frontier + interruption)

---

## 5) Dependencies and modules

### Hive package

- `HiveCore` (dependency-free):
  - runtime, graph compilation, events, and canonical inference contracts.
- `HiveConduit`:
  - adapter that implements `HiveModelClient` using Conduit.
- `HiveCheckpointWax`:
  - adapter that implements `HiveCheckpointStore` using Wax.

### SwiftAgents package

- `SwiftAgents` integrates on top of `HiveCore` and provides the prebuilt `HiveAgents` graph and facade.
- SwiftAgents may optionally depend on `HiveConduit` and `HiveCheckpointWax` to provide defaults, but Hive does not depend on SwiftAgents.


---

## 6) Schema and channel model

### 6.1 HiveSchema

```swift
public protocol HiveSchema: Sendable {
  associatedtype Context: Sendable = Void
  associatedtype Input: Sendable = Void
  associatedtype InterruptPayload: Codable & Sendable = String
  associatedtype ResumePayload: Codable & Sendable = String
  static var channelSpecs: [AnyHiveChannelSpec<Self>] { get }

  /// Converts a typed run input into synthetic writes that are applied
  /// immediately before the next executed step.
  static func inputWrites(_ input: Input, inputContext: HiveInputContext) throws -> [AnyHiveWrite<Self>]
}
```

Default input mapping:

```swift
public extension HiveSchema where Input == Void {
  static func inputWrites(_ input: Void, inputContext: HiveInputContext) throws -> [AnyHiveWrite<Self>] { [] }
}
```

### 6.2 Channel keys and IDs

```swift
public struct HiveChannelID: Hashable, Sendable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct HiveChannelKey<Schema: HiveSchema, Value: Sendable>: Hashable, Sendable {
  public let id: HiveChannelID
  public init(_ id: HiveChannelID) { self.id = id }
}
```

Channel IDs MUST be globally unique within a schema (enforced at compilation).
Runtime maintains a per-attempt type registry keyed by `HiveChannelID`. If a stored value cannot be cast to the requested `Value` type for a `HiveChannelKey`, Hive MUST fail:
- in debug builds: `preconditionFailure(...)`
- in release builds: throw `HiveRuntimeError.channelTypeMismatch(channelID:expectedValueTypeID:actualValueTypeID:)`

### 6.3 Channel spec

```swift
public enum HiveChannelScope: Sendable { case global, taskLocal }
public enum HiveChannelPersistence: Sendable { case checkpointed, untracked }
public enum HiveUpdatePolicy: Sendable { case single, multi }

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

Defaults:
- `updatePolicy = .single` unless explicitly set to `.multi`
- `.taskLocal` must be `.checkpointed` in v1

### 6.4 Codecs (normative)

Codecs are used for checkpoint persistence, hashing/redaction, and task-local fingerprints.

```swift
public protocol HiveCodec: Sendable {
  associatedtype Value: Sendable

  /// Stable identifier included in schemaVersion hashing.
  var id: String { get }

  /// MUST return canonical bytes (deterministic).
  /// `decode(encode(x)) == x` MUST hold for all representable values.
  func encode(_ value: Value) throws -> Data
  func decode(_ data: Data) throws -> Value
}

public struct HiveAnyCodec<Value: Sendable>: Sendable {
  public let id: String
  private let _encode: @Sendable (Value) throws -> Data
  private let _decode: @Sendable (Data) throws -> Value

  public init<C: HiveCodec>(_ codec: C) where C.Value == Value {
    self.id = codec.id
    self._encode = codec.encode
    self._decode = codec.decode
  }

  public func encode(_ value: Value) throws -> Data { try _encode(value) }
  public func decode(_ data: Data) throws -> Value { try _decode(data) }
}
```

### 6.5 AnyHiveChannelSpec (type erasure, normative)

Hive uses a type-erased channel spec list for compilation validation and runtime registry construction.

```swift
public struct AnyHiveChannelSpec<Schema: HiveSchema>: Sendable {
  public let id: HiveChannelID
  public let scope: HiveChannelScope
  public let persistence: HiveChannelPersistence
  public let updatePolicy: HiveUpdatePolicy

  /// Diagnostic only (not a checkpoint compatibility contract).
  /// SHOULD equal `String(reflecting: Value.self)` for the underlying typed spec.
  public let valueTypeID: String

  /// Equal to `codec?.id`, else nil.
  public let codecID: String?

  internal let _initialBox: @Sendable () -> any Sendable
  /// Applies the underlying reducer. MUST throw on type mismatch.
  internal let _reduceBox: @Sendable (any Sendable, any Sendable) throws -> any Sendable
  internal let _encodeBox: (@Sendable (any Sendable) throws -> Data)?
  internal let _decodeBox: (@Sendable (Data) throws -> any Sendable)?
}
```

Registry validation (v1):
- At graph compilation, Hive MUST build a registry keyed by `HiveChannelID.rawValue`.
- If an ID appears more than once, compilation MUST fail with `HiveCompilationError.duplicateChannelID` for the smallest duplicated channel ID (lexicographic by UTF-8).
- v1 restriction: if any channel spec declares `scope == .taskLocal` and `persistence == .untracked`, compilation MUST fail with `HiveCompilationError.invalidTaskLocalUntracked(channelID:)`.

### 6.6 Writes (normative)

```swift
public struct AnyHiveWrite<Schema: HiveSchema>: Sendable {
  public let channelID: HiveChannelID
  public let value: any Sendable
  public init<Value: Sendable>(_ key: HiveChannelKey<Schema, Value>, _ value: Value) {
    self.channelID = key.id
    self.value = value
  }
}

/// Deterministic ordering key inside a task output `writes` array.
public typealias HiveWriteEmissionIndex = Int
```

---

## 7) Store model

### 7.1 Initial value evaluation and caching (normative, v1)

Channel `initial()` closures MUST be deterministic and side-effect free.

Rules:
- `initial()` MUST be evaluated **at most once per run attempt per channel ID**.
- Before executing any steps, Hive MUST build an `initialCache` by evaluating every channel spec’s `initial()` exactly once, in ascending lexicographic `HiveChannelID.rawValue` order.
- All “missing value” reads and all task-local fingerprint computations MUST use the cached initial values from `initialCache`, not by re-invoking `initial()`.

### 7.2 Store types (normative)

```swift
public struct HiveGlobalStore<Schema: HiveSchema>: Sendable {
  public init() {}
  public func get<Value: Sendable>(_ key: HiveChannelKey<Schema, Value>) throws -> Value
}

/// Overlay only: contains explicitly-set task-local values.
public struct HiveTaskLocalStore<Schema: HiveSchema>: Sendable {
  public static var empty: HiveTaskLocalStore<Schema> { get }
  public func get<Value: Sendable>(_ key: HiveChannelKey<Schema, Value>) throws -> Value?
  public mutating func set<Value: Sendable>(_ key: HiveChannelKey<Schema, Value>, _ value: Value) throws
}

/// Read-only composed view of (global + task-local overlay + initialCache).
public struct HiveStoreView<Schema: HiveSchema>: Sendable {
  public func get<Value: Sendable>(_ key: HiveChannelKey<Schema, Value>) throws -> Value
}
```

Global snapshot initialization (v1):
- When initializing a fresh thread state (no in-memory state) **or** when decoding a checkpoint to replace in-memory state, Hive MUST construct a `HiveGlobalStore` snapshot that contains a value for **every** schema-declared `.global` channel ID:
  - Start from the cached `initialCache` values for all `.global` channels.
  - If a checkpoint is being loaded, override values for channels that are `.global` + `.checkpointed` with the decoded checkpoint values.
- When continuing from an existing in-memory thread state, Hive MUST reuse the existing global snapshot (it MUST NOT be reset from `initialCache`).
- The baseline global snapshot selected by §10.0 “Thread state” is the `preStepGlobal` for the attempt’s first executed step.

Read semantics (v1):
- For `.global` keys, `HiveStoreView.get` MUST return the current value from the global snapshot.
- For `.taskLocal` keys, `HiveStoreView.get` MUST return the overlay value if present, else `initialCache` for that channel.

Scope safety (v1):
- If a key’s `channelID` does not exist in the schema registry, `HiveGlobalStore.get`, `HiveTaskLocalStore.get`, `HiveTaskLocalStore.set`, and `HiveStoreView.get` MUST throw `HiveRuntimeError.unknownChannelID(channelID:)`.
- If a key’s `channelID` exists but its declared `HiveChannelScope` does not match the store being accessed (e.g., a `.global` key passed to `HiveTaskLocalStore`), the access MUST throw `HiveRuntimeError.scopeMismatch(channelID:expected:actual:)`.

Untracked channels (v1):
- `.untracked` channels MAY exist in the global store during a run attempt.
- `.untracked` channels are excluded from checkpoints.
- On resume (or any load-from-checkpoint initialization), `.untracked` channels MUST be reset from `initialCache`.

### 7.3 Task-local fingerprint (normative, v1)

For a given task-local overlay, compute the **effective** task-local view:
- For each `.taskLocal` channel, the effective value is overlay value if present, else `initialCache`.
- Task-local codecs are required in v1; the effective value MUST be encoded using the channel codec canonical bytes.

Encode failure (v1, deterministic):
- If `codec.encode(effectiveValue)` throws for any `.taskLocal` channel while computing a task-local fingerprint:
  - The current operation MUST fail (commit fails / resume fails before step 0) by throwing:
    `HiveRuntimeError.taskLocalFingerprintEncodeFailed(channelID: <that channelID>, errorDescription: <redacted-or-debug string per §13.3>)`.
  - Deterministic selection:
    - During commit: tasks are processed in ascending `taskOrdinal`, and within a task fingerprint computation processes channels in ascending `HiveChannelID.rawValue` order, so the first thrown error in that scan order is the error thrown.
    - During resume validation: frontier tasks are processed in persisted frontier order (ascending `taskOrdinal`), and within a task fingerprint computation uses the same channel ordering.

Canonical bytes:
- Sort entries by `HiveChannelID.rawValue` lexicographically (UTF-8).
- Build canonical bytes with an unambiguous framing:
  - Start with ASCII `HLF1`
  - Append `<entryCount:UInt32 BE>`
  - For each entry append `<idLen:UInt32 BE><idUTF8Bytes><valueLen:UInt32 BE><valueBytes>`

Hash:
- Hash canonical bytes with SHA-256; the fingerprint is the 32-byte digest.

Task local propagation (v1):
- Task-local overlays do **not** propagate across static edges/routers/joins
- Only explicit `spawn` / Send creates tasks with non-empty taskLocal overlays

---

## 8) Reducers

```swift
public struct HiveReducer<Value: Sendable>: Sendable {
  private let _reduce: @Sendable (Value, Value) throws -> Value
  public init(_ reduce: @escaping @Sendable (Value, Value) throws -> Value) { self._reduce = reduce }
  public func reduce(current: Value, update: Value) throws -> Value { try _reduce(current, update) }
}
```

Standard reducers:
- lastWriteWins
- append (arrays)
- appendNonNil (optionals)
- setUnion
- dictionaryMerge(valueReducer:)

Standard reducer semantics (v1):
- `lastWriteWins`: returns `update` and ignores `current`.
- `append` (for ordered collections like arrays): returns `current` followed by `update` (stable concatenation; preserves element order).
- `appendNonNil` (for optional ordered collections): treats `nil` as the empty collection; reduces by concatenation and returns `nil` iff both are `nil`.
- `setUnion` (for sets): returns `current ∪ update`.
- `dictionaryMerge(valueReducer:)` (for `[String: V]`): merges keys from `update` into `current`; for key conflicts, reduces values using `valueReducer`, processing update keys in ascending lexicographic order by UTF-8 bytes.

Update policy:
- `.single` throws if >1 write targets the channel in a step
- `.multi` applies reducer sequentially in deterministic order

Scope interaction (v1):
- For `.global` channels, updatePolicy is enforced across **all tasks** in the superstep.
- For `.taskLocal` channels, updatePolicy is enforced **per task-local overlay** (i.e., per task); different tasks may each write the same `.taskLocal` channel once in the same superstep.

---

## 9) Graph builder and compilation

Graph supports:
- static edges: node -> node
- join edges: [nodeA, nodeB, ...] -> node (barrier)
- conditional routing: node -> router(store) -> next nodes

### 9.0 Compilation errors (normative, v1)

`HiveGraphBuilder.compile(...)` MUST throw `HiveCompilationError` on any validation failure.

```swift
public enum HiveCompilationError: Error, Sendable {
  /// Multiple channel specs declare the same `HiveChannelID`.
  case duplicateChannelID(HiveChannelID)
  /// v1 restriction: `.taskLocal` channels MUST be `.checkpointed`.
  case invalidTaskLocalUntracked(channelID: HiveChannelID)

  case startEmpty
  case duplicateStartNode(HiveNodeID)

  case duplicateNodeID(HiveNodeID)
  /// Reserved due to canonical join ID formatting.
  case invalidNodeIDContainsReservedJoinCharacters(nodeID: HiveNodeID)

  case unknownStartNode(HiveNodeID)
  case unknownEdgeEndpoint(from: HiveNodeID, to: HiveNodeID, unknown: HiveNodeID)

  case duplicateRouter(from: HiveNodeID)
  case unknownRouterFrom(HiveNodeID)

  case invalidJoinEdgeParentsEmpty(target: HiveNodeID)
  case invalidJoinEdgeParentsContainsDuplicate(parent: HiveNodeID, target: HiveNodeID)
  case invalidJoinEdgeParentsContainsTarget(target: HiveNodeID)
  case unknownJoinParent(parent: HiveNodeID, target: HiveNodeID)
  case unknownJoinTarget(target: HiveNodeID)
  case duplicateJoinEdge(joinID: String)

  case outputProjectionUnknownChannel(HiveChannelID)
  case outputProjectionIncludesTaskLocal(HiveChannelID)
}
```

Deterministic validation order (v1):
- Compilation MUST run validations in this order, and MUST throw the first failure encountered:
  1) Schema/channel registry validation (§6.5).
  2) Graph structural validation (§9.3).
  3) Compiled output projection validation (§9.2).
- Tie-breakers when multiple violations exist within a single validation rule:
  - For duplicate channel IDs: throw `.duplicateChannelID` for the smallest `HiveChannelID.rawValue` lexicographically.
  - For duplicate node IDs: throw `.duplicateNodeID` for the smallest `HiveNodeID.rawValue` lexicographically.
  - For invalid node IDs containing reserved `+`/`:`: throw `.invalidNodeIDContainsReservedJoinCharacters` for the smallest `HiveNodeID.rawValue` lexicographically.
  - For all validations that scan an ordered list (`start`, static edges insertion order, join edges insertion order): throw the first violation encountered in that scan order.

### 9.1 Core identifiers and routing types (normative)

```swift
public struct HiveNodeID: Hashable, Codable, Sendable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

public enum HiveNext: Sendable {
  /// Follow the compiled graph’s router/static edges for this node.
  case useGraphEdges

  /// Schedule no next tasks.
  case end

  /// Schedule these next nodes in the given order.
  case nodes([HiveNodeID])
}

public typealias HiveRouter<Schema: HiveSchema> = @Sendable (HiveStoreView<Schema>) -> HiveNext
```

Ordering rule (v1):
- Any time Hive must sort node IDs or channel IDs, it MUST sort by `rawValue` lexicographically by UTF-8 bytes.

`HiveNext` normalization (v1):
- `HiveNext.nodes([])` MUST be treated as `.end` (schedule no next tasks).

Join semantics:
- Join edges implement LangGraph-style “waiting edge” semantics via a reusable named barrier.
- Each join edge `J = (parents: Set<HiveNodeID>, target: HiveNodeID)` maintains persistent state:
  - `seenParents: Set<HiveNodeID>` (initially empty)
  - The barrier is **available** iff `seenParents == parents`.
- **Parent contribution rule (v1, LangGraph parity)**: All tasks (both `.graph` and `.spawn`) contribute to join barriers.
  - During a successful step commit, for each executed task whose `nodeID` is in `parents`, insert that `nodeID` into `seenParents`.
  - Duplicate contributions within the same barrier cycle are ignored (set semantics).
- **Barrier cycle (v1)**:
  - A cycle begins immediately after a successful consumption/reset and ends at the next successful consumption/reset.
  - Within a cycle, each parent may contribute at most once; additional executions of the same parent before consumption are ignored, even across multiple steps.
- **Scheduling rule (v1)**: A join edge schedules its `target` task **exactly once** when the barrier transitions from not-available to available due to new parent contributions in a committed step.
  - The scheduled task executes in the **next** superstep.
  - The scheduled task’s task-local overlay MUST be empty (graph-scheduled).
- **Consumption/reset rule (v1, matches LangGraph `NamedBarrierValue.consume`)**:
  - Join barriers are consumed/reset only by executions where `HiveTask.nodeID == target` (regardless of provenance).
  - At the start of the step commit phase (before applying any writes and before applying parent contributions for that step), for each executed task whose `nodeID == target`, Hive MUST attempt to consume the barrier:
    - If the barrier is available (`seenParents == parents`), set `seenParents = []`.
    - Otherwise, do nothing (partial progress is never cleared).
- Consequences:
  - If `target` runs “early” via another edge/router while the barrier is not available, the barrier is not reset.
  - If the barrier is available and `target` runs for any reason, the barrier is reset (consumed) and a new cycle may begin in later steps.
- Ordering consequence:
  - Consumption happens before parent contributions in the same step. If `target` executes in a step where all parents also execute, the barrier may be consumed and then refilled during that commit, which schedules `target` again for the next step (at most one schedule per join edge per step).
- Join barrier IDs are canonical: `join:<parentA>+<parentB>+...:<target>` where parents are sorted lexicographically by node ID.
- Because canonical join barrier IDs are built by concatenating raw node IDs with `+` and `:`, `HiveNodeID.rawValue` MUST NOT contain `+` or `:`. Compilation MUST fail if violated.
- Barrier state (`seenParents`) is persisted in checkpoints so resume preserves join progress.

Routers:
- synchronous
- deterministic
- evaluated per task using that task's composed view plus its own writes (fresh read; see Runtime step algorithm)
- MUST NOT observe other tasks’ writes from the same superstep
- The runtime MUST preserve the exact order returned in `HiveNext.nodes(...)`; it MUST NOT re-sort router outputs (dedupe later keeps the first occurrence).
- If a router’s output is derived from an unordered collection, it MUST sort by `HiveNodeID.rawValue` lexicographically by UTF-8 bytes.

Compilation validation:
- See §9.3 for the normative validation rules and `HiveCompilationError` mapping.

Compilation outputs:
- `schemaVersion` and `graphVersion` strings used for checkpoint compatibility checks (see Checkpointing)

### 9.2 Output projection (normative, v1)

```swift
public enum HiveOutputProjection: Sendable {
  case fullStore
  case channels([HiveChannelID])   // Stored normalized: unique + sorted lexicographically
}
```

Rules:
- Normalization (v1):
  - For `HiveOutputProjection.channels(ids)`, Hive MUST normalize by:
    1) converting `ids` to a unique set by `HiveChannelID.rawValue`
    2) sorting ascending lexicographically by UTF-8 bytes of `rawValue`
  - The compiled graph’s `outputProjection` MUST store the normalized list.
  - Per-run overrides MUST be normalized the same way before use.
- `HiveOutputProjection.channels(...)` MUST refer only to schema-declared `.global` channels.
  - For the compiled graph projection, unknown channels MUST fail compilation with `HiveCompilationError.outputProjectionUnknownChannel`, and `.taskLocal` channels MUST fail compilation with `HiveCompilationError.outputProjectionIncludesTaskLocal`.
  - For per-run overrides, unknown or `.taskLocal` channels MUST fail before step 0 with `HiveRuntimeError.invalidRunOptions`.

### 9.3 Graph builder and compiled graph (normative, v1)

```swift
public struct HiveCompiledNode<Schema: HiveSchema>: Sendable {
  public let id: HiveNodeID
  public let retryPolicy: HiveRetryPolicy
  public let run: HiveNode<Schema>
}

public struct HiveJoinEdge: Hashable, Sendable {
  /// Canonical ID: `join:<sortedParentsJoinedBy+>:<target>`
  public let id: String
  /// Sorted lexicographically, unique, non-empty, and MUST NOT contain `target`.
  public let parents: [HiveNodeID]
  public let target: HiveNodeID
}

public struct CompiledHiveGraph<Schema: HiveSchema>: Sendable {
  public let schemaVersion: String
  public let graphVersion: String
  public let start: [HiveNodeID]                 // ordered
  public let outputProjection: HiveOutputProjection

  /// All nodes keyed by ID.
  public let nodesByID: [HiveNodeID: HiveCompiledNode<Schema>]

  /// Static edges adjacency list (per `from` node, `to` list is in builder insertion order).
  public let staticEdgesByFrom: [HiveNodeID: [HiveNodeID]]

  /// Join edges in builder insertion order.
  public let joinEdges: [HiveJoinEdge]

  /// Routers keyed by `from` node.
  /// If present, router takes precedence over static edges for that node (unless it returns `.useGraphEdges`, which falls back to static edges).
  public let routersByFrom: [HiveNodeID: HiveRouter<Schema>]
}

public struct HiveGraphBuilder<Schema: HiveSchema> {
  public init(start: [HiveNodeID])

  public mutating func addNode(
    _ id: HiveNodeID,
    retryPolicy: HiveRetryPolicy = .none,
    _ node: @escaping HiveNode<Schema>
  )
  public mutating func addEdge(from: HiveNodeID, to: HiveNodeID)
  public mutating func addJoinEdge(parents: [HiveNodeID], target: HiveNodeID)
  public mutating func addRouter(from: HiveNodeID, _ router: @escaping HiveRouter<Schema>)
  public mutating func setOutputProjection(_ projection: HiveOutputProjection)

  public func compile(graphVersionOverride: String? = nil) throws -> CompiledHiveGraph<Schema>
}
```

Builder ordering rules (v1):
- Static edge order is the order `addEdge` was called (insertion order).
- Join edge order is the order `addJoinEdge` was called (insertion order).

Compilation validation (v1, minimum):
- Node IDs MUST be unique.
- `HiveNodeID.rawValue` MUST NOT contain `+` or `:` (reserved for canonical join IDs).
- `start` MUST be non-empty and MUST contain no duplicates.
- All edge/router/join references MUST refer to known node IDs.
- Adding more than one router for the same `from` node MUST fail compilation.
- Join edge parents MUST be non-empty and MUST NOT contain duplicates.
- Join edge parents MUST NOT contain the `target` node ID.
- Join barrier IDs MUST be unique; adding the same join edge twice (same canonical barrier ID) MUST fail compilation.

Compilation error mapping (v1):
- Duplicate node IDs → `HiveCompilationError.duplicateNodeID`.
- Reserved join characters in node IDs → `HiveCompilationError.invalidNodeIDContainsReservedJoinCharacters`.
- Empty start list → `HiveCompilationError.startEmpty`.
- Duplicate start node → `HiveCompilationError.duplicateStartNode`.
- Unknown start node → `HiveCompilationError.unknownStartNode`.
- Unknown static edge endpoint → `HiveCompilationError.unknownEdgeEndpoint`.
- Duplicate router for a node → `HiveCompilationError.duplicateRouter`.
- Router attached to unknown node ID → `HiveCompilationError.unknownRouterFrom`.
- Join edge `parents` empty → `HiveCompilationError.invalidJoinEdgeParentsEmpty`.
- Join edge `parents` contains duplicates → `HiveCompilationError.invalidJoinEdgeParentsContainsDuplicate`.
- Join edge `parents` contains `target` → `HiveCompilationError.invalidJoinEdgeParentsContainsTarget`.
- Join edge references unknown parent → `HiveCompilationError.unknownJoinParent`.
- Join edge references unknown target → `HiveCompilationError.unknownJoinTarget`.
- Duplicate canonical join ID → `HiveCompilationError.duplicateJoinEdge`.

Versioning (v1):
- `schemaVersion` MUST be computed from `Schema.channelSpecs` using the canonical bytes in Checkpointing.
- `graphVersion` MUST be computed from the compiled graph using the canonical bytes in Checkpointing, unless `graphVersionOverride` is provided (in which case the override string is used verbatim).

---

## 10) Runtime execution (supersteps)

### 10.0 Runtime configuration and public API (normative, v1)

Thread serialization (v1):
- Hive is single-writer per `HiveThreadID`.
- For the same `threadID`, `run(...)`, `resume(...)`, and `applyExternalWrites(...)` MUST be serialized by the runtime (queued, not concurrent).
- The runtime MAY execute operations for different `threadID`s concurrently.

#### Checkpoint policy

```swift
public enum HiveCheckpointPolicy: Sendable {
  case disabled
  case everyStep
  case every(steps: Int)   // steps >= 1
  case onInterrupt
}
```

Rules (v1):
- If `checkpointPolicy != .disabled`, a `checkpointStore` MUST be configured or the attempt fails before step 0.
- A checkpoint is saved only at attempt/step boundaries (never mid-step).
- Save schedule:
  - `.everyStep`: save after every committed step boundary.
  - `.every(steps: k)`: save after a committed step boundary iff `checkpoint.stepIndex % k == 0`.
  - `.onInterrupt`: save only when an interrupt is produced (forced).
  - `.disabled`: do not save during normal execution.
- If the run interrupts, Hive MUST save exactly one checkpoint for that boundary regardless of `checkpointPolicy`.
  - If `checkpointPolicy` would also save at that same boundary, Hive still saves only once.
- If a checkpoint save is required at a boundary and `checkpointStore.save(...)` throws, the boundary MUST NOT commit and the attempt MUST fail with that error (propagated).

#### Run options

```swift
public struct HiveRunOptions: Sendable {
  public let maxSteps: Int
  public let maxConcurrentTasks: Int
  public let checkpointPolicy: HiveCheckpointPolicy
  public let debugPayloads: Bool
  public let deterministicTokenStreaming: Bool
  public let eventBufferCapacity: Int

  /// If non-nil, overrides the compiled graph’s `outputProjection` for this attempt.
  public let outputProjectionOverride: HiveOutputProjection?

  public init(
    maxSteps: Int = 100,
    maxConcurrentTasks: Int = 8,
    checkpointPolicy: HiveCheckpointPolicy = .disabled,
    debugPayloads: Bool = false,
    deterministicTokenStreaming: Bool = false,
    eventBufferCapacity: Int = 4096,
    outputProjectionOverride: HiveOutputProjection? = nil
  ) {
    self.maxSteps = maxSteps
    self.maxConcurrentTasks = maxConcurrentTasks
    self.checkpointPolicy = checkpointPolicy
    self.debugPayloads = debugPayloads
    self.deterministicTokenStreaming = deterministicTokenStreaming
    self.eventBufferCapacity = eventBufferCapacity
    self.outputProjectionOverride = outputProjectionOverride
  }
}
```

Validation (v1):
- `maxSteps` MUST be >= 0.
- `maxConcurrentTasks` MUST be >= 1.
- `eventBufferCapacity` MUST be >= 1.
- For `checkpointPolicy == .every(steps: k)`, `k` MUST be >= 1; otherwise the attempt MUST fail before step 0 with `HiveRuntimeError.invalidRunOptions`.
- If `outputProjectionOverride == .channels(ids)`, it MUST be normalized to unique + sorted lexicographically before use.

Default `HiveRunOptions` (v1):
- `maxSteps = 100`
- `maxConcurrentTasks = 8`
- `checkpointPolicy = .disabled`
- `debugPayloads = false`
- `deterministicTokenStreaming = false`
- `eventBufferCapacity = 4096`
- `outputProjectionOverride = nil`

#### Clock and logger

```swift
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
```

#### Checkpoint store type-erasure

```swift
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

#### Environment

```swift
public struct HiveEnvironment<Schema: HiveSchema>: Sendable {
  public let context: Schema.Context
  public let clock: any HiveClock
  public let logger: any HiveLogger

  /// Optional adapter dependencies (used by prebuilt nodes, not required by HiveCore).
  public let model: AnyHiveModelClient?
  public let modelRouter: (any HiveModelRouter)?
  public let inferenceHints: HiveInferenceHints?
  public let tools: AnyHiveToolRegistry?

  public let checkpointStore: AnyHiveCheckpointStore<Schema>?

  public init(
    context: Schema.Context,
    clock: any HiveClock,
    logger: any HiveLogger,
    model: AnyHiveModelClient? = nil,
    modelRouter: (any HiveModelRouter)? = nil,
    inferenceHints: HiveInferenceHints? = nil,
    tools: AnyHiveToolRegistry? = nil,
    checkpointStore: AnyHiveCheckpointStore<Schema>? = nil
  ) {
    self.context = context
    self.clock = clock
    self.logger = logger
    self.model = model
    self.modelRouter = modelRouter
    self.inferenceHints = inferenceHints
    self.tools = tools
    self.checkpointStore = checkpointStore
  }
}
```

#### Output + run handle

```swift
public struct HiveProjectedChannelValue: Sendable {
  public let id: HiveChannelID
  public let value: any Sendable

  public init(id: HiveChannelID, value: any Sendable) {
    self.id = id
    self.value = value
  }
}

public enum HiveRunOutput<Schema: HiveSchema>: Sendable {
  case fullStore(HiveGlobalStore<Schema>)
  /// Values are returned in the same order as the projection’s channel ID list.
  case channels([HiveProjectedChannelValue])
}

public enum HiveRunOutcome<Schema: HiveSchema>: Sendable {
  case finished(output: HiveRunOutput<Schema>, checkpointID: HiveCheckpointID?)
  case interrupted(interruption: HiveInterruption<Schema>)
  case cancelled(output: HiveRunOutput<Schema>, checkpointID: HiveCheckpointID?)
  case outOfSteps(maxSteps: Int, output: HiveRunOutput<Schema>, checkpointID: HiveCheckpointID?)
}

public struct HiveRunHandle<Schema: HiveSchema>: Sendable {
  public let runID: HiveRunID
  public let attemptID: HiveRunAttemptID
  public let events: AsyncThrowingStream<HiveEvent, Error>
  public let outcome: Task<HiveRunOutcome<Schema>, Error>
}
```

#### Runtime API

```swift
public actor HiveRuntime<Schema: HiveSchema>: Sendable {
  public init(graph: CompiledHiveGraph<Schema>, environment: HiveEnvironment<Schema>)

  public func run(
    threadID: HiveThreadID,
    input: Schema.Input,
    options: HiveRunOptions
  ) -> HiveRunHandle<Schema>

  public func resume(
    threadID: HiveThreadID,
    interruptID: HiveInterruptID,
    payload: Schema.ResumePayload,
    options: HiveRunOptions
  ) -> HiveRunHandle<Schema>

  public func applyExternalWrites(
    threadID: HiveThreadID,
    writes: [AnyHiveWrite<Schema>],
    options: HiveRunOptions
  ) -> HiveRunHandle<Schema>

  public func getLatestStore(threadID: HiveThreadID) -> HiveGlobalStore<Schema>?
  public func getLatestCheckpoint(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>?
}
```

API semantics (v1):
- Thread state (v1):
  - `HiveRuntime` MUST maintain an in-memory per-thread state keyed by `HiveThreadID` containing at least:
    - `runID`, `stepIndex`
    - global snapshot (`HiveGlobalStore`)
    - frontier (tasks to execute at the next step boundary)
    - join barrier progress (`seenParents` per join edge)
    - pending `interruption` if the run is paused
    - `latestCheckpointID` (the most recent successfully saved checkpoint ID, if any)
  - Fresh thread initialization:
    - If no in-memory state exists and no checkpoint is loaded, Hive MUST initialize:
      - `runID = HiveRunID(UUID())`
      - `stepIndex = 0`
      - global snapshot per §7.2 (all `.global` channels set to `initialCache`)
      - frontier = `[]`
      - join barrier `seenParents = []` for every compiled join edge ID
      - interruption = `nil`
      - latestCheckpointID = `nil`
- Baseline state resolution for `run(...)` and `applyExternalWrites(...)` (v1):
  - If an in-memory state exists for `threadID`, Hive MUST use it as the baseline and MUST NOT load from `checkpointStore`.
  - Otherwise, if `checkpointStore` is configured:
    - Hive MUST call `checkpointStore.loadLatest(threadID:)`.
    - If `loadLatest` throws, the attempt MUST fail before step 0 by throwing that error and MUST NOT initialize a fresh thread state.
    - If `loadLatest` returns `nil`, initialize a fresh thread state.
    - If `loadLatest` returns a checkpoint, decode it into the baseline state (after version validation) and set `latestCheckpointID = checkpoint.id`.
  - Otherwise, initialize a fresh thread state.
- All “fail before step 0” rules in this spec refer to failing after `runStarted` is emitted but before emitting any `stepStarted` event.
- `run(...)`:
  - Hive MUST resolve baseline state per “Thread state” above.
  - If a checkpoint was loaded, Hive MUST validate `schemaVersion` and `graphVersion` match the compiled graph before executing step 0; otherwise fail with `HiveRuntimeError.checkpointVersionMismatch`.
  - If the resolved baseline state contains a pending interruption, `run(...)` MUST fail before step 0 with `HiveRuntimeError.interruptPending`.
  - Frontier seeding:
    - If the loaded (or in-memory) frontier is non-empty, the attempt continues from that frontier.
    - If the loaded (or in-memory) frontier is empty, the attempt MUST seed the frontier from `CompiledHiveGraph.start` (each as a graph task with empty task-local overlay) before executing the first step.
      - The `start` array order MUST be preserved exactly (no sorting); assigned ordinals follow this order.
      This enables multi-turn “invoke again after completion” behavior.
  - Apply `Schema.inputWrites(input, inputContext: ...)` as synthetic writes before the first executed step (see Inputs).
- `resume(...)`:
  - Requires a configured `checkpointStore`; otherwise fails before step 0.
  - Loads the latest checkpoint for `threadID` (ignoring any in-memory state). If `checkpointStore.loadLatest(threadID:)` throws, the attempt MUST fail before step 0 by throwing that error.
  - Validates:
    - `schemaVersion` and `graphVersion` match the compiled graph
    - `interruptID` matches the checkpoint’s pending interruption
  - On a successful load+validation, the in-memory state for `threadID` MUST be replaced with the decoded checkpoint state before executing step 0, and `latestCheckpointID` MUST be set to the loaded checkpoint’s `id`.
  - Continues from the persisted frontier.
- `applyExternalWrites(...)`:
  - Hive MUST resolve baseline state per “Thread state” above.
  - If a checkpoint was loaded, Hive MUST validate `schemaVersion` and `graphVersion` match the compiled graph before committing the synthetic step.
  - If the resolved baseline state contains a pending interruption, `applyExternalWrites(...)` MUST fail before committing with `HiveRuntimeError.interruptPending`.
  - Applies the provided writes as a synthetic committed step with an **empty frontier**:
    - Join barriers are not consumed or updated (no nodes executed).
    - Writes MUST target schema-declared `.global` channels only:
      - If any write targets an unknown `channelID`, the synthetic step MUST fail with `HiveRuntimeError.unknownChannelID` and MUST NOT commit.
      - If any write targets a `.taskLocal` channel, the synthetic step MUST fail with `HiveRuntimeError.taskLocalWriteNotAllowed` and MUST NOT commit.
      - For each write, Hive MUST validate the write value type matches the channel’s expected value type:
        - in debug builds: `preconditionFailure(...)` on mismatch
        - in release builds: fail the synthetic step with `HiveRuntimeError.channelTypeMismatch(...)` and MUST NOT commit
    - Global writes are applied in the array order provided (as if from a single task), enforcing updatePolicy:
      - `.single` fails if the same channel is written more than once, with `HiveRuntimeError.updatePolicyViolation(channelID: channelID, policy: .single, writeCount: writeCount)` where `writeCount` is the number of provided writes targeting that channel ID.
      - `.multi` reduces sequentially in array order; if the reducer throws, the synthetic step MUST fail and MUST NOT commit.
    - The persisted frontier remains unchanged.
    - `stepIndex` is incremented by 1 (because a step boundary was committed).
  - If `checkpointStore` is configured, Hive MUST save a checkpoint for this synthetic step regardless of `checkpointPolicy`.
  - Outcome and events for `applyExternalWrites(...)` (v1):
    - On success, `applyExternalWrites(...)` MUST return `HiveRunOutcome.finished(output: ..., checkpointID: ...)`.
    - `applyExternalWrites(...)` commits exactly one synthetic step with an empty frontier at the thread’s current `stepIndex = S`, then terminates.
    - The synthetic step MUST emit deterministic events exactly as a committed step with `frontierCount = 0`:
      1) `stepStarted(stepIndex: S, frontierCount: 0)`
      2) no `taskStarted` / stream / `taskFinished` events
      3) `writeApplied` for each written `.global` channel in ascending `HiveChannelID.rawValue` order
      4) `checkpointSaved` iff a checkpoint was saved for this boundary
      5) `stepFinished(stepIndex: S, nextFrontierCount: <persisted frontier count>)`
      6) `runFinished` as the terminal event
- `getLatestStore(threadID:)` MUST return the current in-memory global snapshot for `threadID` (if present), and MUST NOT perform any checkpoint store I/O.
- `getLatestCheckpoint(threadID:)` MUST call `checkpointStore.loadLatest(threadID:)` if a checkpoint store is configured; otherwise it MUST return `nil`.

### 10.1 Identifiers

```swift
public struct HiveRunID: Hashable, Codable, Sendable {
  public let rawValue: UUID
  public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

public struct HiveRunAttemptID: Hashable, Codable, Sendable {
  public let rawValue: UUID
  public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

public struct HiveThreadID: Hashable, Codable, Sendable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Lowercase hex of a 32-byte SHA-256 digest.
public struct HiveTaskID: Hashable, Codable, Sendable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}
```

`HiveInputContext` (v1):

```swift
public struct HiveInputContext: Sendable {
  public let threadID: HiveThreadID
  public let runID: HiveRunID
  /// The next step index to execute for this attempt (the step index of the first `stepStarted` emitted by this attempt).
  public let stepIndex: Int

  public init(threadID: HiveThreadID, runID: HiveRunID, stepIndex: Int) {
    self.threadID = threadID
    self.runID = runID
    self.stepIndex = stepIndex
  }
}
```

Semantics (v1):
- `HiveRunID` identifies the persisted run state for a `threadID` and MUST be reused across resumes and future run attempts on that same thread (loaded from checkpoint when present).
- `HiveRunAttemptID` is generated fresh for each call to `run(...)`, `resume(...)`, or `applyExternalWrites(...)` as `HiveRunAttemptID(UUID())`.
- `HiveTaskID` is derived deterministically from `(runID, stepIndex, nodeID, ordinal, localFingerprint)` (see Task ID derivation below).

### 10.2 Input/output semantics

Inputs:
- `run(threadID:input:...)` MUST map `input` to synthetic writes via `Schema.inputWrites(input, inputContext: ...)` where:
  - `inputContext.threadID = threadID`
  - `inputContext.runID = resolved baseline state runID`
  - `inputContext.stepIndex = resolved baseline state stepIndex` (the next step to execute for this attempt)
- These writes MUST be applied immediately before the first executed step of the attempt and are visible to all tasks in that step.
- Input writes MUST be applied as `.global` writes to the global store using the same reducer + updatePolicy semantics as normal step commits.
- `Schema.inputWrites(input, inputContext: ...)` MUST target schema-declared `.global` channels only:
  - If any write targets an unknown `channelID`, the attempt MUST fail before step 0 with `HiveRuntimeError.unknownChannelID`.
  - If any write targets a `.taskLocal` channel, the attempt MUST fail before step 0 with `HiveRuntimeError.taskLocalWriteNotAllowed`.
- If applying input writes produces an updatePolicy violation or a reducer throws, the attempt MUST fail before step 0.

Input writes validation + events (v1):
- Applying `Schema.inputWrites` is NOT a superstep and MUST NOT emit `stepStarted`, `stepFinished`, or `writeApplied` events.
- Input writes MUST be validated and applied after `runStarted` (and after `checkpointLoaded`/`runResumed` when applicable) and before emitting the attempt’s first `stepStarted`.
- Input writes MUST be treated as `.global` writes from a single synthetic writer:
  - scan writes in array order (0-based) as `writeEmissionIndex`
  - enforce `.single` with `writeCount =` the number of input writes targeting that channel ID
  - apply `.multi` reducers sequentially in array order
- Unknown channel IDs or write value type mismatches MUST fail before step 0 using this same scan order and the same errors as commit-time write validation.

Outputs:
- The attempt returns a `HiveRunOutcome` whose `output` is computed from:
  - the compiled graph’s `outputProjection`, unless overridden by `HiveRunOptions.outputProjectionOverride`
- Default is `.fullStore`.
- `checkpointID` semantics (v1):
  - For `.finished`, `.cancelled`, and `.outOfSteps`, `checkpointID` MUST equal the thread’s `latestCheckpointID` at the end of the attempt (or `nil` if no checkpoint has ever been saved for the thread).
  - For `.interrupted`, `checkpointID` is always present and equals the checkpoint saved for the interrupt boundary.

### 10.3 Tasks and nodes (normative)

Nodes execute as async functions that receive an immutable store view and return explicit outputs.

```swift
public struct HiveTaskSeed<Schema: HiveSchema>: Sendable {
  public let nodeID: HiveNodeID
  public let local: HiveTaskLocalStore<Schema>
  public init(nodeID: HiveNodeID, local: HiveTaskLocalStore<Schema> = .empty) {
    self.nodeID = nodeID
    self.local = local
  }
}

/// Distinguishes graph-scheduled tasks (LangGraph "pull") from `spawn` tasks (LangGraph "push"/Send).
public enum HiveTaskProvenance: String, Codable, Sendable {
  /// Scheduled via start/static edges/routers/join edges.
  case graph
  /// Scheduled via `HiveNodeOutput.spawn` (Send).
  case spawn
}

public struct HiveTask<Schema: HiveSchema>: Sendable {
  public let id: HiveTaskID
  public let ordinal: Int         // 0-based index in the step frontier
  public let provenance: HiveTaskProvenance
  public let nodeID: HiveNodeID
  public let local: HiveTaskLocalStore<Schema>
}

public struct HiveRunContext<Schema: HiveSchema>: Sendable {
  public let runID: HiveRunID
  public let threadID: HiveThreadID
  public let attemptID: HiveRunAttemptID
  public let stepIndex: Int
  public let taskID: HiveTaskID
  public let resume: HiveResume<Schema>?
}

public typealias HiveNode<Schema: HiveSchema> =
  @Sendable (HiveNodeInput<Schema>) async throws -> HiveNodeOutput<Schema>

public struct HiveNodeInput<Schema: HiveSchema>: Sendable {
  public let store: HiveStoreView<Schema>
  public let run: HiveRunContext<Schema>
  public let context: Schema.Context
  public let environment: HiveEnvironment<Schema>
  public let emitStream: @Sendable (_ kind: HiveStreamEventKind, _ metadata: [String: String]) -> Void
  public let emitDebug: @Sendable (_ name: String, _ metadata: [String: String]) -> Void
}

/// Stream-only event kinds that nodes/adapters may emit via `HiveNodeInput.emitStream`.
public enum HiveStreamEventKind: Sendable {
  case modelInvocationStarted(model: String)
  case modelToken(text: String)
  case modelInvocationFinished
  case toolInvocationStarted(name: String)
  case toolInvocationFinished(name: String, success: Bool)
  case customDebug(name: String)
}

public struct HiveNodeOutput<Schema: HiveSchema>: Sendable {
  public var writes: [AnyHiveWrite<Schema>]
  public var spawn: [HiveTaskSeed<Schema>]
  public var next: HiveNext
  public var interrupt: HiveInterruptRequest<Schema>?

  public init(
    writes: [AnyHiveWrite<Schema>] = [],
    spawn: [HiveTaskSeed<Schema>] = [],
    next: HiveNext = .useGraphEdges,
    interrupt: HiveInterruptRequest<Schema>? = nil
  ) {
    self.writes = writes
    self.spawn = spawn
    self.next = next
    self.interrupt = interrupt
  }
}
```

Node-emitted events (v1):
- `HiveNodeInput.emitDebug(name, metadata)` MUST emit `HiveEventKind.customDebug(name:)` for the current `(stepIndex, taskOrdinal)`.
- `HiveNodeInput.emitStream(kind, metadata)` MUST emit the provided stream event kind for the current `(stepIndex, taskOrdinal)`.
  - The runtime MUST map `HiveStreamEventKind` to the corresponding `HiveEventKind` case.

Task ID derivation (v1):
- When building a step frontier list for step `S`, assign `ordinal = index` (0-based).
- `runUUIDBytes` MUST be the 16 raw RFC 4122 bytes of `HiveRunID.rawValue`.
- `S` MUST be representable as `UInt32`; otherwise the attempt MUST fail before executing the step with `HiveRuntimeError.stepIndexOutOfRange(stepIndex: S)`.
- `ordinal` MUST be representable as `UInt32`; otherwise the attempt MUST fail before executing the step with `HiveRuntimeError.taskOrdinalOutOfRange(ordinal: ordinal)`.
- `nodeIDUTF8` MUST be `HiveNodeID.rawValue` encoded as UTF-8 bytes.
- `localFingerprint32` MUST be exactly 32 bytes.
- Compute `taskIDBytes = SHA256( runUUIDBytes || UInt32BE(S) || 0x00 || nodeIDUTF8 || 0x00 || UInt32BE(ordinal) || localFingerprint32 )`.
- `HiveTaskID.rawValue` is lowercase hex of `taskIDBytes`.

### 10.4 Step algorithm (normative)

For each step `S`:

**Compute phase**
- Execute all tasks in `frontier` concurrently, bounded by `HiveRunOptions.maxConcurrentTasks`.
- Each task’s node MUST receive a `HiveStoreView` composed from:
  - the step’s `preStepGlobal` snapshot
  - the task’s `local` overlay
  - the attempt’s `initialCache`
  This view MUST NOT include any writes from any task in the current step (including the task itself).
- Each task executes the compiled node with that node’s `HiveRetryPolicy`:
  - On failure, retry per policy using `HiveEnvironment.clock.sleep(...)` with deterministic backoff.
  - Failed-attempt outputs MUST be discarded.
  - The final successful attempt’s output is used for commit; if retries are exhausted, the task fails.

**Commit phase (deterministic)**
- Define `taskOrdinal = frontier index` (0-based). This is the only task ordering key in v1.
- Let `preStepGlobal` be the global store snapshot at the start of step `S`.
- Step commit implementation MUST be atomic:
  - The runtime MUST compute `postStepGlobal`, updated join barriers, and the next frontier into working copies.
  - If a checkpoint is required at this boundary (per `HiveCheckpointPolicy`, `applyExternalWrites`, or an interrupt), the runtime MUST also compute the checkpoint and call `checkpointStore.save(checkpoint)` **before** publishing the new in-memory state.
    - When a checkpoint is required at a boundary, the runtime MUST successfully complete `checkpointStore.save(...)` before emitting any commit-scoped deterministic events for that boundary (`writeApplied`, `checkpointSaved`, `stepFinished`, and any terminal run event), so that a save failure cannot leak “committed” events for an uncommitted step.
  - The runtime MUST only replace the persisted in-memory state with these working copies after all commit-time validations succeed and (when required) the checkpoint save succeeds.

#### Commit-time validation order and failure precedence (normative, v1)

When multiple commit-time violations are possible in the same step, Hive MUST evaluate and report failures deterministically.

For a step `S`, commit-time validations MUST run in this exact order and Hive MUST throw the first failure encountered:

1) Validate all task-emitted writes (unknown channel + write value type):
- Define `writeEmissionIndex` as the 0-based index in each task’s `HiveNodeOutput.writes`.
- Scan writes in this exact order:
  - tasks in ascending `taskOrdinal`
  - within a task, writes in ascending `writeEmissionIndex`
- For each write:
  - If `write.channelID` is not present in the schema registry, the step MUST fail with `HiveRuntimeError.unknownChannelID(write.channelID)` and MUST NOT commit.
  - Else, Hive MUST validate `write.value` matches the channel’s expected value type:
    - If the value cannot be cast to that type:
      - in debug builds: `preconditionFailure(...)`
      - in release builds: the step MUST fail with
        `HiveRuntimeError.channelTypeMismatch(channelID: write.channelID, expectedValueTypeID: spec.valueTypeID, actualValueTypeID: String(reflecting: type(of: write.value)))`
        and MUST NOT commit.

2) Enforce `.single` updatePolicy for `.global` channels:
- Process `.global` channels in ascending `HiveChannelID.rawValue` order.
- For each `.global` channel, let `writeCount` be the total number of `.global` writes targeting that channel in the step (across all tasks).
- If `updatePolicy == .single` and `writeCount > 1`, the step MUST fail with
  `HiveRuntimeError.updatePolicyViolation(channelID: channelID, policy: .single, writeCount: writeCount)`
  and MUST NOT commit.

3) Reduce `.global` writes:
- Process `.global` channels in ascending `HiveChannelID.rawValue` order.
- Within each channel, sort writes by `(taskOrdinal, writeEmissionIndex)` ascending and reduce sequentially.
- If the reducer throws, the step MUST fail by throwing that error and MUST NOT commit.

4) Enforce + reduce `.taskLocal` writes:
- Process tasks in ascending `taskOrdinal`.
- Within a task, process `.taskLocal` channels in ascending `HiveChannelID.rawValue` order.
- For each channel, let `writeCount` be the number of `.taskLocal` writes to that channel from this task in the step.
  - If `updatePolicy == .single` and `writeCount > 1`, fail with
    `HiveRuntimeError.updatePolicyViolation(channelID: channelID, policy: .single, writeCount: writeCount)`
    and MUST NOT commit.
  - If `updatePolicy == .multi`, reduce sequentially in ascending `writeEmissionIndex`; if the reducer throws, fail by throwing that error and MUST NOT commit.

5) Router fresh-read view construction (v1, deterministic):
- This validation runs only for tasks whose routing precedence requires evaluating a builder router.
- Process tasks in ascending `taskOrdinal`.
- For each task where a builder router is evaluated, Hive MUST construct the router view `preStepGlobal + thisTaskWrites` exactly as defined in §10.4 "Routing precedence and 'fresh read'".
- If constructing that router view throws for any reason (including a reducer throw while applying `thisTaskWrites`), the step MUST fail by throwing that error and MUST NOT commit.
- If multiple router views would throw, Hive MUST throw the first error encountered in this scan order (smallest `taskOrdinal`).

6) Validate next-step seed node IDs:
- After building `nextGraphSeeds` (including join targets and after dedupe) and `nextSpawnSeeds`, validate node IDs in this exact scan order:
  1) `nextGraphSeeds` in generation order (after dedupe)
  2) `nextSpawnSeeds` in generation order
- If a seed node ID does not exist in `CompiledHiveGraph.nodesByID`, the step MUST fail with
  `HiveRuntimeError.unknownNodeID(<that nodeID>)`
  for the first such seed in this scan order, and MUST NOT commit.

0) Step atomicity:
- If any task ultimately fails after retries are exhausted, the step MUST NOT commit (see Errors).

1) Consume join barriers (deterministic, LangGraph parity):
- This step executes only if the step commits.
- For each executed task in ascending `taskOrdinal`:
  - For each join edge whose `target == task.nodeID`, in `CompiledHiveGraph.joinEdges` array order (builder insertion order), attempt to consume it:
    - If `seenParents == parents`, set `seenParents = []`.
    - Else do nothing.

2) Apply `.global` writes (deterministic):
- For each task output `writes`, define `writeEmissionIndex` as the 0-based index in the array.
- Unknown channel IDs and write value type mismatches are validated per “Commit-time validation order and failure precedence”.
- For each `channelID`, collect all writes that target a `.global` channel.
- Sort writes for that channel by `(taskOrdinal, writeEmissionIndex)` ascending.
- Enforce updatePolicy:
  - If policy is `.single` and there is more than 1 write for that channel in the step, the step MUST fail with
    `HiveRuntimeError.updatePolicyViolation(channelID: channelID, policy: .single, writeCount: writeCount)`
    where `writeCount` is the total number of `.global` writes targeting `channelID` in the step, and MUST NOT commit.
  - If policy is `.multi`, apply the reducer sequentially in the sorted order. If the reducer throws, the step MUST fail and MUST NOT commit.

3) Apply `.taskLocal` writes (deterministic):
- `.taskLocal` writes apply only to the originating task’s local overlay.
- For `.taskLocal` channels, enforce updatePolicy **per task** using that task’s writes sorted by `writeEmissionIndex`.
  - If policy is `.single` and there is more than 1 write for that channel **from the same task** in the step, the step MUST fail with `HiveRuntimeError.updatePolicyViolation(channelID:policy:writeCount:)` where `writeCount` is that per-task count, and MUST NOT commit.
  - If policy is `.multi`, apply the reducer sequentially in `writeEmissionIndex` order. If the reducer throws, the step MUST fail and MUST NOT commit.

4) Routing precedence and “fresh read” (normative):
- Determine routing for each task in ascending `taskOrdinal`:
  1) If `output.next != .useGraphEdges`, use it and DO NOT evaluate any builder router or static edges.
  2) Else if a builder router exists for the node, evaluate it:
     - If the router returns `.useGraphEdges`, Hive MUST fall back to following static edges for the node in builder insertion order (as if no router were present).
     - Otherwise, use the router result and DO NOT follow static edges.
  3) Else follow static edges for the node in builder insertion order.
- Fresh read / isolation:
  - A builder router MUST observe `preStepGlobal + thisTaskWrites` only.
  - It MUST NOT observe any other task’s writes from the same step.
  - “Apply thisTaskWrites” is defined as:
    - Start from `preStepGlobal`.
    - Apply this task’s `.global` writes in ascending `writeEmissionIndex` order, using the same reducer semantics that would apply if this task were the only writer.
    - For `.taskLocal` reads, start from this task’s `local` overlay (with `initialCache` fallbacks) and apply this task’s `.taskLocal` writes in ascending `writeEmissionIndex` order.
  - Fresh-read error handling (v1, deterministic):
    - Routers MUST be evaluated only after commit-time validations (steps 1–4) succeed.
    - For each task in ascending `taskOrdinal` where routing precedence requires evaluating a builder router, Hive MUST construct the fresh-read view and then evaluate routing.
    - Hive MUST construct the router view by (1) applying this task’s `.global` writes, then (2) applying this task’s `.taskLocal` writes.
    - If constructing the router view throws for any reason (including a reducer invocation throw while applying `thisTaskWrites`), the step MUST fail during commit by throwing that error and MUST NOT commit.
    - Router view construction errors are commit-time failures (not task failures): `taskFinished` events for successfully executed tasks are still emitted, and no commit-scoped events (`writeApplied`, `checkpointSaved`, `streamBackpressure`, `stepFinished`) are emitted for the failed step.
    - If multiple tasks would throw, Hive MUST throw the error from the smallest `taskOrdinal` and MUST NOT evaluate routers for higher ordinals.

5) Build `nextFrontierSeeds` (deterministic):
- Iterate tasks in ascending `taskOrdinal`.
- Collect seeds into two ordered lists:
  - `nextGraphSeeds`: seeds produced by routing (`output.next` / builder router / static edges) in the order returned/defined.
  - `nextSpawnSeeds`: seeds produced by `spawn` (Send) in node-emitted order.
- For all routing/static/join-produced seeds, the seed’s taskLocal overlay MUST be empty.

6) Apply parent contributions and schedule join targets:
- Evaluate join edges in builder join-edge insertion order.
- For each join edge:
  - Let `wasAvailable = (seenParents == parents)` after consumption.
  - For each executed task in ascending `taskOrdinal` where `task.nodeID` is in `parents`, insert into `seenParents` (set semantics).
  - Let `isAvailable = (seenParents == parents)` after inserts.
  - If `wasAvailable == false` and `isAvailable == true`, append exactly one join target seed to `nextGraphSeeds` (in this join-edge order).
- Join targets are appended to `nextGraphSeeds` after all routing/static-edge seeds (because join scheduling happens after step 5). They participate in graph-seed dedupe (step 7) and MAY be dropped if the same `(nodeID, localFingerprint)` was scheduled earlier in the same step.

7) Dedupe (graph-scheduled tasks only; LangGraph parity):
- Dedupe applies to `nextGraphSeeds` only.
- Key = `(nodeID, localFingerprint)` (for v1 graph seeds this is effectively `nodeID` because graph seeds MUST have empty task-local overlays).
- Keep the first occurrence by generation order; drop later occurrences.
- No dedupe is performed within or against `nextSpawnSeeds`.

8) Convert seeds into the next step frontier:
- Before assigning ordinals, Hive MUST validate that every `HiveTaskSeed.nodeID` in `nextGraphSeeds` and `nextSpawnSeeds` exists in `CompiledHiveGraph.nodesByID`. If not, fail the step with `HiveRuntimeError.unknownNodeID` and do not commit.
- The next frontier ordering is:
  1) `nextGraphSeeds` in generation order after dedupe
  2) `nextSpawnSeeds` in generation order
- Tasks derived from `nextGraphSeeds` MUST have `provenance = .graph`.
- Tasks derived from `nextSpawnSeeds` MUST have `provenance = .spawn`.
- Assign `ordinal = index` (0-based) in this combined list and compute `HiveTaskID`.
- The next step index is `S + 1`.

Stop conditions and `maxSteps` (v1, deterministic):
- The run stops when the computed next frontier is empty.
- `.end` schedules no next tasks (it is not a node ID).
- `HiveRunOptions.maxSteps` limits the number of steps executed in a single attempt (not the absolute persisted `stepIndex`).
- Let `stepsExecutedThisAttempt = 0` at attempt start.
- Before emitting `stepStarted` for the next step:
  - If `stepsExecutedThisAttempt == options.maxSteps`:
    - If the frontier is empty, finish normally.
    - If the frontier is non-empty, stop immediately without executing another step and return `HiveRunOutcome.outOfSteps(maxSteps: options.maxSteps, ...)`.
- After each successfully committed step, increment `stepsExecutedThisAttempt += 1`.
- `applyExternalWrites(...)` ignores `maxSteps` (it always attempts exactly one synthetic committed step).

---

## 11) Errors, retries, cancellation

### 11.0 Errors (normative, v1)

```swift
public enum HiveRuntimeError: Error, Sendable {
  case invalidRunOptions(String)

  case stepIndexOutOfRange(stepIndex: Int)
  case taskOrdinalOutOfRange(ordinal: Int)

  case checkpointStoreMissing
  case checkpointVersionMismatch(expectedSchema: String, expectedGraph: String, foundSchema: String, foundGraph: String)
  case checkpointDecodeFailed(channelID: HiveChannelID, errorDescription: String)
  case checkpointEncodeFailed(channelID: HiveChannelID, errorDescription: String)
  case checkpointCorrupt(field: String, errorDescription: String)
  case interruptPending(interruptID: HiveInterruptID)
  case noCheckpointToResume
  case noInterruptToResume
  case resumeInterruptMismatch(expected: HiveInterruptID, found: HiveInterruptID)

  case unknownNodeID(HiveNodeID)
  case unknownChannelID(HiveChannelID)
  case scopeMismatch(channelID: HiveChannelID, expected: HiveChannelScope, actual: HiveChannelScope)

  case modelClientMissing
  case modelStreamInvalid(String)
  case toolRegistryMissing

  case missingCodec(channelID: HiveChannelID)
  case channelTypeMismatch(channelID: HiveChannelID, expectedValueTypeID: String, actualValueTypeID: String)
  case taskLocalFingerprintEncodeFailed(channelID: HiveChannelID, errorDescription: String)

  case updatePolicyViolation(channelID: HiveChannelID, policy: HiveUpdatePolicy, writeCount: Int)
  case taskLocalWriteNotAllowed
  case invalidMessagesUpdate
  case missingTaskLocalValue(channelID: HiveChannelID)
}
```

Error timing (v1, minimum):
- `invalidRunOptions` MUST be thrown before step 0.
- `stepIndexOutOfRange` / `taskOrdinalOutOfRange` MUST be thrown before executing the affected step (and before saving a checkpoint whose `stepIndex` is not representable as `UInt32`).
- `checkpointStoreMissing` MUST be thrown before step 0 when a checkpoint store is required (`resume(...)` or `checkpointPolicy != .disabled`).
- `checkpointVersionMismatch` MUST be thrown before step 0.
- `checkpointDecodeFailed` MUST be thrown before step 0.
- `checkpointEncodeFailed` MUST be thrown during commit before any state is committed (and before emitting any commit-scoped deterministic events for that boundary).
- `checkpointCorrupt` MUST be thrown before step 0.
- `missingCodec` MUST be thrown before step 0.
- `unknownNodeID` MUST be thrown during commit before any state is committed.
- `unknownChannelID` MUST be thrown during commit before any state is committed (or before step 0 when validating input/external writes).
- `updatePolicyViolation` MUST be thrown during commit before any state is committed.
- `taskLocalFingerprintEncodeFailed` MUST be thrown either:
  - before step 0 during resume validation, or
  - during commit before any state is committed,
  depending on when the fingerprint computation is required.

Retry policy:
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
- retries clear pending writes from failed attempt
- no jitter in v1
- fail-fast when retries exhausted

### 11.1 Step atomicity (normative, v1)

A step commit is all-or-nothing:
- If any task in the frontier ultimately fails after retries are exhausted, the step MUST NOT commit:
  - no global writes are applied
  - no join barriers are updated
  - no next frontier is produced
  - no checkpoint is saved for that step
- If commit-time validation fails (e.g., updatePolicy violation, unknown node ID), the step MUST NOT commit.
- If a checkpoint is required at the boundary and `checkpointStore.save(...)` throws, the step MUST NOT commit.

### 11.2 Retry backoff determinism (normative, v1)

Backoff formula (no jitter):
- Attempts are 1-based (`attempt = 1` is the first execution).
- For a failure before `attempt+1`, sleep:
  `delay = min(maxNanoseconds, floor(initialNanoseconds * pow(factor, attempt-1)))` as `UInt64`.
- Retry policy validation (v1):
  - For `.exponentialBackoff(...)`:
    - `maxAttempts` MUST be >= 1.
    - `factor` MUST be finite (`isFinite == true`) and MUST be >= 1.0.
  - If any compiled node’s retry policy is invalid, the attempt MUST fail before step 0 with `HiveRuntimeError.invalidRunOptions(...)`.
    - If multiple nodes have invalid retry policies, Hive MUST throw for the smallest `HiveNodeID.rawValue` lexicographically.
- Sleep errors (v1):
  - If `HiveClock.sleep(...)` throws `CancellationError`, the runtime MUST treat the run as cancelled and apply §11.3.
  - If `HiveClock.sleep(...)` throws any other error, the step MUST fail by throwing that error and MUST NOT commit.

Failed-attempt outputs:
- Writes/spawn/next/interrupt produced by a failed attempt MUST be discarded.
- Only the final successful attempt’s output participates in commit.

### 11.3 Cancellation semantics (normative, v1)

A run attempt is considered cancelled when cancellation is observed inside the runtime (`Task.isCancelled == true` at any observation point).

Between steps:
- If cancellation is observed before emitting `stepStarted` for the next step, the runtime MUST stop immediately (no new step begins), emit `runCancelled` as the final event, and complete the outcome as `.cancelled(output: <latest committed projection>, checkpointID: <latestCheckpointID>)`.

During a step:
- If cancellation is observed after `stepStarted(stepIndex: S, ...)` is emitted but before the step commits, the runtime MUST:
  - cancel all in-flight node tasks for that step
  - MUST NOT commit step `S` (no writes, no barrier updates, no frontier changes, no checkpoint for step `S`)
  - emit `taskFailed` for every frontier task in ascending `taskOrdinal` as if the task failed with `CancellationError()`
  - emit `runCancelled` as the final event
  - MUST NOT emit `writeApplied`, `checkpointSaved`, `streamBackpressure`, or `stepFinished` for step `S`

Stream events on cancellation:
- If `deterministicTokenStreaming == true`, buffered stream events for the cancelled step MUST be discarded (never emitted).
- If `deterministicTokenStreaming == false`, already-emitted stream events remain; no further events may be emitted after `runCancelled`.

### 11.4 Task failure error selection (normative, v1)

When an attempt terminates with an error, Hive MUST choose the thrown error deterministically.

Rules:
- If a step fails because one or more tasks ultimately fail after retries are exhausted, Hive MUST:
  - emit `taskFailed` for every failed task in ascending `taskOrdinal` (per §13.5), and
  - terminate the attempt by throwing the **final** error (after retries are exhausted) from the smallest `taskOrdinal` among failed tasks.
- If a step fails due to a commit-time validation failure (including `unknownChannelID`, `channelTypeMismatch`, `updatePolicyViolation`, reducer-throw, or `unknownNodeID`), Hive MUST throw that validation error (per §10.4 “Commit-time validation order and failure precedence”).
- If a step fails because a required checkpoint save throws, Hive MUST throw that save error.
- Cancellation is not an error and MUST NOT use these rules (see §11.3).

---

## 12) Interrupt / resume

Non-goal clarification (v1):
- Hive v1 does NOT support a LangGraph-Python-style mid-node resumable `interrupt()` (exception that rewinds/re-executes node logic).
- In Hive v1, interrupts are requested via `HiveNodeOutput.interrupt` and are observed only at committed step boundaries (per §12.2).

### 12.1 Types (normative)

```swift
public struct HiveInterruptID: Hashable, Codable, Sendable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Node output requests an interrupt; runtime assigns an ID deterministically.
public struct HiveInterruptRequest<Schema: HiveSchema>: Codable, Sendable {
  public let payload: Schema.InterruptPayload
  public init(payload: Schema.InterruptPayload) { self.payload = payload }
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

### 12.2 Interrupt rules (normative, v1)

- A node requests an interrupt by setting `HiveNodeOutput.interrupt = HiveInterruptRequest(payload: ...)`.
- Interrupt selection:
  - If multiple tasks request interrupts in the same committed step, Hive MUST select the request from the smallest `taskOrdinal` and ignore later requests (while still committing all deterministic writes).
- Interrupt ID derivation (v1, deterministic):
  - Let `winningTaskID` be the selected task’s `HiveTaskID`.
  - Hive MUST set `interrupt.id.rawValue` to the lowercase hex SHA-256 digest of:
    `ASCII(\"HINT1\") || UTF8(winningTaskID.rawValue)`.
- Interrupt checkpointing:
  - Interrupts require a configured `checkpointStore` at the interrupt boundary.
    - If a committed step contains an interrupt request and no `checkpointStore` is configured, the step MUST fail during commit with `HiveRuntimeError.checkpointStoreMissing` and MUST NOT commit.
  - On interrupt, Hive MUST save exactly one checkpoint at the step boundary (regardless of `checkpointPolicy`) so the run is always resumable.
  - If that checkpoint save throws, the step MUST NOT commit and the attempt MUST fail with that error.

Interrupt termination (normative, v1):
- Interrupt selection applies only if the step would otherwise commit successfully.
- If an interrupt request is selected in a committed step `S`, Hive MUST:
  1) compute the normal post-step state (global writes, task-local updates, join barrier updates, and the next frontier for `S+1`)
  2) set `threadState.interruption = selectedInterrupt` in-memory
  3) save exactly one checkpoint for that boundary whose `interruption` field equals the selected interrupt and whose `frontier` equals the computed next frontier
  4) emit `stepFinished` for step `S`
  5) terminate the attempt immediately (MUST NOT execute step `S+1` in the same attempt), returning `HiveRunOutcome.interrupted(interruption: ...)` and emitting `runInterrupted(...)` as the terminal event

Precedence:
- If an interrupt request is selected, it takes precedence over normal completion: even if the computed next frontier is empty, the attempt MUST return `.interrupted`, not `.finished`.

### 12.3 Resume rules (normative, v1)

- `resume(...)` requires a configured `checkpointStore`. If none is configured, the attempt MUST fail before step 0.
- Hive MUST load the latest checkpoint for `threadID`.
  - If `checkpointStore.loadLatest(threadID:)` throws, the attempt MUST fail before step 0 by throwing that error.
- Hive MUST validate:
  - If no checkpoint exists for `threadID`, fail with `HiveRuntimeError.noCheckpointToResume`.
  - The checkpoint has a non-nil `interruption`; otherwise fail with `HiveRuntimeError.noInterruptToResume`.
  - The stored `interruption.id` matches the provided `interruptID`.
- Resume visibility:
  - On a successful `resume(...)` attempt, Hive MUST set `HiveRunContext.resume` to `HiveResume(interruptID:..., payload:...)` for all tasks executed in the first step of that attempt only.
  - For subsequent steps in the same attempt, `HiveRunContext.resume` MUST be `nil`.
- Clearing the pending interruption (v1, deterministic):
  - The checkpoint’s `interruption` represents a paused boundary and MUST remain pending unless/until the resume attempt successfully commits at least one step.
  - If a `resume(...)` attempt terminates before committing any step (error or cancellation), Hive MUST NOT clear `threadState.interruption` and MUST NOT save any new checkpoint.
  - When the first step of a `resume(...)` attempt commits successfully, the committed post-step state MUST set `threadState.interruption = nil` unless a new interrupt request is selected in that same committed step (in which case `threadState.interruption` becomes that new selected interrupt per §12.2).

---

## 13) Events and streaming (normative)

### 13.1 Event ID and ordering

Hive emits a single event stream for:
- run/step/task lifecycle
- write application
- checkpoint save/load
- model/tool adapter events
- debug-only diagnostics

Canonical ordering key (v1):
- Events MUST be delivered in stream order; deterministic events MUST be deterministic (see 13.2).
- `HiveEventID.eventIndex` is the canonical total order for a single run attempt.

```swift
public struct HiveEventID: Hashable, Codable, Sendable {
  public let runID: HiveRunID
  public let attemptID: HiveRunAttemptID
  public let eventIndex: UInt64       // 0-based, monotonically increasing per attempt
  public let stepIndex: Int?          // nil for run-level events
  public let taskOrdinal: Int?        // nil unless task-scoped
}
```

### 13.2 Event kinds (v1)

```swift
public struct HiveEvent: Sendable {
  public let id: HiveEventID
  public let kind: HiveEventKind
  public let metadata: [String: String]
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
```

Deterministic delivery (v1):
- Hive defines two delivery classes:
  - **Deterministic events**: all events except `modelInvocationStarted`, `modelToken`, `modelInvocationFinished`, `toolInvocationStarted`, `toolInvocationFinished`, `customDebug`.
  - **Stream events**: `modelInvocationStarted`, `modelToken`, `modelInvocationFinished`, `toolInvocationStarted`, `toolInvocationFinished`, `customDebug`.
- Deterministic events MUST be emitted in an order that is independent of task completion timing.
- Stream events MAY be delivered live and MAY interleave across concurrent tasks; ordering MUST be preserved within a single task’s stream (per `(stepIndex, taskOrdinal)`).
- Deterministic stream mode (v1):
  - If `deterministicTokenStreaming == true`, all stream events MUST be buffered per task during compute and MUST NOT be emitted live.
  - After compute completes for the step, Hive MUST emit buffered stream events in a deterministic order:
    - tasks in ascending `taskOrdinal`
    - within each task, preserve the adapter-produced stream order
  - In this mode, stream events MUST NOT interleave across tasks.

Retries and stream events (normative, v1):
- `taskStarted`/`taskFinished`/`taskFailed` are per-task events (not per retry attempt) and MUST be emitted at most once each per task.
- In `deterministicTokenStreaming == true` mode:
  - stream events MUST be buffered per retry attempt
  - stream events from failed attempts MUST be discarded
  - only the final successful attempt’s stream events are emitted
- In `deterministicTokenStreaming == false` mode:
  - stream events are emitted live as produced
  - stream events emitted before an attempt fails are not retracted; later retry attempts may emit additional stream events

Required ordering constraints (v1):
- For each step `S`, `stepStarted(stepIndex: S, ...)` MUST be emitted before any task-scoped or stream event for step `S`.
- For each task `T`, `taskStarted(..., taskID: T.id)` MUST be emitted before any stream events for `T`, and `taskFinished`/`taskFailed` MUST be emitted after the last stream event for `T`.
- `writeApplied` events for a step MUST be emitted after all `taskFinished` events for that step.
- If emitted, `streamBackpressure` MUST be emitted immediately before `stepFinished` for that step.

Deterministic event sequencing (v1):
- At attempt start:
  1) `runStarted`
  2) `checkpointLoaded` (only if a checkpoint was successfully loaded, decoded, and validated into the baseline state)
  3) `runResumed` (only for `resume(...)` attempts)
- For each committed step `S`:
  1) `stepStarted(stepIndex: S, frontierCount: ...)`
  2) `taskStarted` for each frontier task in ascending `taskOrdinal`
  3) After compute completes:
     - If `deterministicTokenStreaming == true`: emit buffered stream events for each task in ascending `taskOrdinal`
     - Emit `taskFinished` / `taskFailed` for each frontier task in ascending `taskOrdinal`
  4) During commit: emit `writeApplied` once per `.global` channel that had ≥1 write in the step, in ascending `HiveChannelID.rawValue` order. The `payloadHash` MUST be computed from the **post-reduction** value that was committed for that channel.
  5) `checkpointSaved` (only if a checkpoint was saved for this step)
  6) `streamBackpressure` (only if any droppable events were dropped during this step)
  7) `stepFinished(stepIndex: S, nextFrontierCount: ...)`
- At attempt end:
  - Normal completion emits `runFinished` after the final `stepFinished`.
  - Interrupt completion emits `runInterrupted` after the interrupt checkpoint is saved and after the step’s `stepFinished`.
  - Cancellation emits `runCancelled` as the final event.
  - Out-of-steps completion emits `runFinished` as the final event (the reason is visible only via `HiveRunOutcome.outOfSteps`).

### 13.3 Hashing and redaction (v1)

For `writeApplied.payloadHash`, Hive MUST compute a SHA-256 hash of canonical bytes:
- If the channel has a codec: `codec.encode(value)`; if `codec.encode(value)` throws, Hive MUST fall back to stable JSON bytes if the value is `Encodable`, else `UTF-8("unhashable:" + valueTypeID)`
- Else if the value is `Encodable`: stable JSON bytes using `JSONEncoder` with:
  - `outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`
  - `dateEncodingStrategy = .iso8601`
  - `dataEncodingStrategy = .base64`
- Else: `UTF-8(\"unhashable:\" + valueTypeID)`

The hash string is lowercase hex.

Debug payloads (v1):
- If `HiveRunOptions.debugPayloads == false`:
  - `writeApplied` MUST NOT include any full payload bytes/JSON in `HiveEvent.metadata`.
  - `taskFailed.errorDescription` MUST be a redacted, UI-safe string: `String(describing: type(of: error))`.
- If `HiveRunOptions.debugPayloads == true`:
  - `writeApplied` MUST include full payload data in `HiveEvent.metadata` using these keys:
    - `valueTypeID`: the channel spec’s `valueTypeID`
    - `codecID`: the channel spec’s `codecID` if present, else the empty string
    - `payloadEncoding`: one of `codec.base64`, `json.utf8`, `unhashable`
    - `payload`: for `codec.base64`, `Base64(codec.encode(value))` (if `codec.encode` throws, fall back to `json.utf8` or `unhashable`); for `json.utf8`, the UTF-8 JSON string; for `unhashable`, the empty string
  - `taskFailed.errorDescription` MUST be `String(reflecting: error)`.

### 13.4 Backpressure (normative, v1)

Buffer:
- Default capacity: 4096 events (configurable per run).

Event classes (v1):
- Droppable: `modelToken`, `customDebug`.
- Non-droppable: all other event kinds.

Overflow algorithm (v1, deterministic):
- When enqueueing a droppable `modelToken` event and the buffer is full:
  1) If the last buffered event is also a `modelToken` for the same `(stepIndex, taskOrdinal)`, coalesce by appending text to the last token event (no new enqueue).
  2) Otherwise, drop the new token event and increment `droppedModelTokenEvents`.
- When enqueueing a droppable debug-only event and the buffer is full: drop it and increment `droppedDebugEvents`.
- When enqueueing a non-droppable event and the buffer is full: the producer MUST suspend until space is available.

Deterministic token streaming buffering and memory bounds (v1):
- When `deterministicTokenStreaming == true`, stream events are buffered per task during compute.
- To prevent unbounded memory growth, each task’s buffered stream event list MUST be bounded by `eventBufferCapacity` (interpreted as “max buffered stream events per task”).
- When buffering in this mode:
  - `modelToken` and `customDebug` MUST apply the same drop/coalesce policy as above, but scoped to that task’s buffer (keyed by `(stepIndex, taskOrdinal)` which is constant within the buffer).
  - Non-droppable stream events (`modelInvocationStarted`, `modelInvocationFinished`, `toolInvocationStarted`, `toolInvocationFinished`) MUST be buffered. If this would exceed the per-task bound, Hive MUST fail the step by throwing `HiveRuntimeError.modelStreamInvalid(...)` (programmer error).

Diagnostic:
- If any droppable events were dropped during a step, emit exactly one non-droppable `streamBackpressure` event immediately before `stepFinished` with the per-step dropped counts.

### 13.5 Event stream termination and failure (normative, v1)

- For attempts that complete with a `HiveRunOutcome` (`finished`, `interrupted`, `cancelled`, `outOfSteps`), `HiveRunHandle.events` MUST finish normally after emitting the corresponding terminal run event.
- If an attempt fails with an error (including task failures after retries are exhausted, commit-time validation failures, checkpoint store I/O errors, or checkpoint decode errors), then:
  - `HiveRunHandle.outcome` MUST throw that error.
  - `HiveRunHandle.events` MUST finish by throwing that same error.
  - No events may be emitted after the error is thrown from the stream.
- Step finalization:
  - `stepFinished` is emitted only for committed steps.
  - If a step fails and does not commit, Hive MUST still emit `stepStarted`, `taskStarted` (all tasks), and `taskFinished`/`taskFailed` (all tasks) deterministically, then terminate the attempt with an error **without** emitting `writeApplied`, `checkpointSaved`, `streamBackpressure`, or `stepFinished` for that step.
  - Cancellation is not an error: if a step does not commit due to cancellation, Hive MUST follow §11.3 and MUST NOT terminate the event stream by throwing.
- Stream events on failed steps (v1):
  - If `deterministicTokenStreaming == true` and a step fails with a non-cancellation error:
    - After compute completes for the step, Hive MUST emit buffered stream events for each task in ascending `taskOrdinal` before emitting `taskFinished`/`taskFailed`.
    - For a task that ultimately fails after retries are exhausted, no stream events are emitted (all failed-attempt buffers are discarded per §13.2).
  - If `deterministicTokenStreaming == false`, any stream events emitted before the failure remain; no special handling is required beyond the termination rule above.

---

## 14) Checkpointing (normative)

### 14.1 Snapshot contents (v1)

Snapshot MUST include:
- `threadID`, `runID`, `stepIndex`
- `schemaVersion`, `graphVersion`
- global store values (checkpointed channels only)
- frontier tasks for `stepIndex`, in order (each includes `nodeID`, `provenance`, `localFingerprint`, and `localDataByChannelID`)
- join barrier state (per canonical join barrier ID: sorted list of parents seen; may be partially-filled or fully available)
- interruption payload if present

Untracked channels are excluded from checkpoints by definition.

Step index (v1):
- `stepIndex` in a checkpoint is the **next step index to execute on resume** (i.e., the state is “at the boundary before stepIndex”).
- A checkpoint saved after committing step `N` MUST use `stepIndex = N + 1` and persist the computed next frontier.
- On a fresh run with no loaded checkpoint, `stepIndex` starts at 0.
- On resume, the first executed step uses `checkpoint.stepIndex`, and the persisted `frontier` corresponds to that step boundary in the exact saved order.

### 14.2 Checkpoint types and store contract (v1)

```swift
public struct HiveCheckpointID: Hashable, Codable, Sendable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct HiveCheckpointTask: Codable, Sendable {
  public let provenance: HiveTaskProvenance
  public let nodeID: HiveNodeID
  public let localFingerprint: Data              // 32 bytes
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

  /// Encoded values for all checkpointed `.global` channels (keyed by channel id string).
  public let globalDataByChannelID: [String: Data]

  /// The persisted frontier.
  public let frontier: [HiveCheckpointTask]

  /// Join barrier progress keyed by canonical join barrier ID.
  /// Each `seenParents` list MUST be sorted lexicographically for stable encoding.
  public let joinBarrierSeenByJoinID: [String: [String]]

  /// Present only when the run is paused.
  public let interruption: HiveInterrupt<Schema>?
}

public protocol HiveCheckpointStore: Sendable {
  associatedtype Schema: HiveSchema
  func save(_ checkpoint: HiveCheckpoint<Schema>) async throws
  func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>?
}
```

Checkpoint ID derivation (v1, deterministic):
- For any checkpoint saved by `HiveRuntime`, `HiveCheckpointID.rawValue` MUST be the lowercase hex SHA-256 digest of:
  `ASCII(\"HCP1\") || runUUIDBytes || UInt32BE(checkpoint.stepIndex)`,
  where `runUUIDBytes` is the 16 raw RFC 4122 bytes of `checkpoint.runID.rawValue`.
- `checkpoint.stepIndex` MUST be representable as `UInt32`; otherwise the attempt MUST fail before saving with `HiveRuntimeError.stepIndexOutOfRange(stepIndex:)`.

Atomicity (v1):
- `save` MUST be atomic with respect to `loadLatest`.
- After `save(checkpoint)` returns successfully, a subsequent `loadLatest(threadID:)` MUST return `checkpoint` or a checkpoint with a greater `stepIndex`.
- `loadLatest` MUST never return a partially-written checkpoint.

Definition of “latest” (v1):
- Latest = checkpoint with maximum `stepIndex`.
- Tie-breaker: maximum `checkpoint.id.rawValue` lexicographically.

Checkpoint encoding rules (v1):
- `globalDataByChannelID` MUST contain an entry for every `.global` channel with `persistence == .checkpointed`.
- Each `globalDataByChannelID[id]` value MUST equal `codec.encode(currentValue)` using that channel’s codec canonical bytes.
- `frontier` order MUST match the runtime frontier order at the boundary before `stepIndex`.
- `HiveCheckpointTask.localDataByChannelID` MUST contain only `.taskLocal` overlay entries that were explicitly set for that task; missing task-local channels are reconstructed from `initialCache` on resume.
- Each `HiveCheckpointTask.localDataByChannelID[id]` value MUST equal `codec.encode(value)` using that task-local channel’s codec canonical bytes.
- `HiveCheckpointTask.localFingerprint` MUST be exactly 32 bytes and MUST equal the SHA-256 fingerprint described in Store Model (computed over the effective task-local view).
- On resume, the persisted `frontier` array order defines `taskOrdinal` (0-based), and `HiveTaskID` MUST be recomputed from `(runID, stepIndex, nodeID, ordinal, localFingerprint)` using §10.3.
- `joinBarrierSeenByJoinID` MUST contain an entry for every compiled join edge ID (even if the `seenParents` list is empty). Each `seenParents` list MUST be sorted lexicographically by `HiveNodeID.rawValue`.

Checkpoint encode failures (v1, deterministic):
- If any required `codec.encode(...)` throws while constructing a checkpoint to be saved by the runtime, the boundary MUST fail during commit with:
  `HiveRuntimeError.checkpointEncodeFailed(channelID: <that channelID>, errorDescription: <redacted-or-debug string per §13.3>)`,
  MUST NOT commit, and MUST NOT emit any commit-scoped deterministic events for that boundary.
- Deterministic selection: choose the first failing channel in ascending `HiveChannelID.rawValue` order, scanning all required checkpointed `.global` channels first, then scanning frontier tasks in ascending `taskOrdinal` and within each task scanning `localDataByChannelID` keys in ascending lexicographic order.

Checkpoint decode rules (v1):
- When loading a checkpoint, Hive MUST decode each required checkpointed value using the schema channel’s codec:
  - For every compiled `.global` channel with `persistence == .checkpointed`, the checkpoint MUST contain `globalDataByChannelID[channelID]`.
  - For every `HiveCheckpointTask.localDataByChannelID` entry, the channel ID MUST refer to a compiled `.taskLocal` channel.
- If any required entry is missing or any `codec.decode(...)` throws, the attempt MUST fail before step 0 with `HiveRuntimeError.checkpointDecodeFailed(channelID:errorDescription:)`.
- Additional structural validation (v1):
  - `checkpoint.globalDataByChannelID` MUST NOT contain entries for any channel ID that is not a compiled `.global` + `.checkpointed` channel; otherwise fail before step 0 with `HiveRuntimeError.checkpointCorrupt(field: "globalDataByChannelID", errorDescription: ...)`.
  - `checkpoint.frontier[*].localFingerprint` MUST be exactly 32 bytes; otherwise fail before step 0 with `HiveRuntimeError.checkpointCorrupt(field: "frontier.localFingerprint", errorDescription: ...)`.
  - For each frontier task, Hive MUST reconstruct the effective task-local view (overlay values + `initialCache` fallbacks), recompute the task-local fingerprint (§7.3), and verify it equals the stored `localFingerprint`; otherwise fail before step 0 with `HiveRuntimeError.checkpointCorrupt(field: "frontier.localFingerprint", errorDescription: ...)`.
    - If recomputing the fingerprint fails due to an encode failure, fail before step 0 with `HiveRuntimeError.taskLocalFingerprintEncodeFailed(...)` per §7.3.
  - `checkpoint.joinBarrierSeenByJoinID` MUST contain exactly the compiled join edge IDs as keys (no missing keys and no extra keys). Otherwise fail before step 0 with `HiveRuntimeError.checkpointCorrupt(field: "joinBarrierSeenByJoinID", errorDescription: ...)`.
  - For each join edge ID, the `seenParents` list MUST:
    - be sorted ascending lexicographically by UTF-8 bytes
    - contain no duplicates
    - contain only parent node IDs that are members of that join edge’s `parents` set
    Otherwise fail before step 0 with `HiveRuntimeError.checkpointCorrupt(field: "joinBarrierSeenByJoinID", errorDescription: ...)`.

### 14.3 Versioning and canonical hashing (v1)

Resume MUST fail before step execution if `schemaVersion` or `graphVersion` mismatches the compiled graph.

Router closures cannot be hashed. If router logic changes without a structural graph change, `graphVersion` may remain unchanged; v1 MUST allow an explicit graphVersion override at compile time.

All version hashes are lowercase hex SHA-256 digests of canonical bytes.

String encoding (v1):
- All `<...Len>` fields are counts of UTF-8 bytes.
- All `<...UTF8>` fields are the raw UTF-8 bytes of the exact string values (no Unicode normalization).

#### schemaVersion bytes (HSV1)

Build bytes:
- Start with ASCII `HSV1`
- Append byte `C`
- Append `<channelCount:UInt32 BE>`
- For each channel spec sorted by `HiveChannelID.rawValue`:
  - `<idLen:UInt32 BE><idUTF8>`
  - `<scope:UInt8>` global=0, taskLocal=1
  - `<persistence:UInt8>` checkpointed=0, untracked=1
  - `<updatePolicy:UInt8>` single=0, multi=1
  - `<codecIdLen:UInt32 BE><codecIdUTF8>`; empty string if no codec

#### graphVersion bytes (HGV1)

Build bytes:
- Start with ASCII `HGV1`
- Append section `S` + `<startCount:UInt32 BE>` + start node IDs in builder-provided order:
  - `<idLen:UInt32 BE><idUTF8>`
- Append section `N` + `<nodeCount:UInt32 BE>` + nodes sorted by node ID:
  - `<idLen:UInt32 BE><idUTF8>`
  - (This includes all nodes in `CompiledHiveGraph.nodesByID`, including unreachable nodes.)
- Append section `R` + `<routerFromCount:UInt32 BE>` + node IDs that have a builder router (sorted):
  - `<idLen:UInt32 BE><idUTF8>`
- Append section `E` + `<edgeCount:UInt32 BE>` + static edges in builder insertion order:
  - `<fromLen:UInt32 BE><fromUTF8><toLen:UInt32 BE><toUTF8>`
- Append section `J` + `<joinEdgeCount:UInt32 BE>` + join edges in builder insertion order:
  - `<targetLen:UInt32 BE><targetUTF8>`
  - `<parentCount:UInt32 BE>` + parents sorted lexicographically:
    - `<parentLen:UInt32 BE><parentUTF8>`
- Append section `O` + `<projectionKind:UInt8>`:
  - 0 = full store snapshot
  - 1 = explicit list, followed by `<count:UInt32 BE>` and channel IDs sorted lexicographically (`<idLen:UInt32 BE><idUTF8>`)

### 14.4 Codec requirements and failure timing (v1)

Codec requirements:
- All checkpointed global channels MUST have codecs.
- All taskLocal channels MUST have codecs.
- `.untracked` global channels MAY omit codecs.

Failure timing:
- Missing codec checks MUST run once per attempt after `initialCache` is built and before any checkpoint decode or node execution.
- Missing codecs MUST fail with `HiveRuntimeError.missingCodec(channelID:)` before step 0.
- If multiple required codecs are missing, Hive MUST throw for the smallest `HiveChannelID.rawValue` lexicographically.

---

## 15) Hybrid inference

HiveCore defines canonical chat/tool types and minimal adapter contracts used by `HiveConduit` and SwiftAgents’ Hive integration.

### 15.1 Canonical chat + tool types (HiveCore)

```swift
public enum HiveChatRole: String, Codable, Sendable {
  case system, user, assistant, tool
}

public struct HiveToolDefinition: Codable, Sendable {
  public let name: String
  public let description: String
  /// JSON Schema string (UTF-8) describing tool arguments.
  public let parametersJSONSchema: String
}

public struct HiveToolCall: Codable, Sendable {
  public let id: String
  public let name: String
  /// JSON string (UTF-8) for tool arguments.
  public let argumentsJSON: String
}

public struct HiveToolResult: Codable, Sendable {
  public let toolCallID: String
  public let content: String
}

/// Special operations for the `messages` reducer (SwiftAgents prebuilt graph).
public enum HiveChatMessageOp: String, Codable, Sendable {
  /// Delete the message with this `id`.
  case remove
  /// Delete all messages; the reducer resets history at this marker (see SwiftAgents-on-Hive spec).
  case removeAll
}

public struct HiveChatMessage: Codable, Sendable {
  public let id: String
  public let role: HiveChatRole
  public let content: String
  public let name: String?
  public let toolCallID: String?
  public let toolCalls: [HiveToolCall]
  public let op: HiveChatMessageOp?
}
```

### 15.2 Model client (HiveCore)

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
  /// MUST be emitted exactly once and MUST be the final chunk if the stream completes successfully.
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
```

Model streaming contract (v1):
- `HiveModelClient.stream` MAY emit zero or more `.token` chunks.
- If the stream completes successfully, it MUST emit exactly one `.final(HiveChatResponse)` chunk and it MUST be the last emitted chunk.
- `HiveModelClient.complete` MUST return the same `HiveChatResponse` that would be produced by the `.final(...)` chunk for the same request.

### 15.3 Tool registry (HiveCore)

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

### 15.4 Hybrid inference hints and routing

```swift
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

Rule (v1):
- If `HiveEnvironment.modelRouter` is provided, prebuilt nodes MUST call it to choose a model client per request (passing `HiveEnvironment.inferenceHints` when available). Otherwise they MUST use `HiveEnvironment.model`.

---

## 16) SwiftAgents on Hive (prebuilt)

SwiftAgents ships a prebuilt chat+tools agent graph (“HiveAgents”) and a small façade that wires `HiveRuntime` with safe defaults. The implementation lives in the SwiftAgents package (not in Hive).

### 16.1 Public types (normative, v1)

```swift
public enum HiveAgentsToolApprovalPolicy: Sendable {
  case never
  case always
  case allowList(Set<String>) // tool names
}

public enum HiveAgents {
  public static let removeAllMessagesID = "__remove_all__"

  public enum ToolApprovalDecision: String, Codable, Sendable { case approved, rejected }

  public enum Interrupt: Codable, Sendable {
    case toolApprovalRequired(toolCalls: [HiveToolCall])
  }

  public enum Resume: Codable, Sendable {
    case toolApproval(decision: ToolApprovalDecision)
  }

  public static func makeToolUsingChatAgent(
    preModel: HiveNode<Schema>? = nil,
    postModel: HiveNode<Schema>? = nil
  ) throws -> CompiledHiveGraph<Schema>
}

public protocol HiveTokenizer: Sendable {
  func countTokens(_ messages: [HiveChatMessage]) -> Int
}

public struct HiveCompactionPolicy: Sendable {
  public let maxTokens: Int
  public let preserveLastMessages: Int

  public init(maxTokens: Int, preserveLastMessages: Int) {
    self.maxTokens = maxTokens
    self.preserveLastMessages = preserveLastMessages
  }
}

public struct HiveAgentsContext: Sendable {
  public let modelName: String
  public let tools: [HiveToolDefinition]
  public let toolApprovalPolicy: HiveAgentsToolApprovalPolicy
  public let compactionPolicy: HiveCompactionPolicy?
  public let tokenizer: (any HiveTokenizer)?

  public init(
    modelName: String,
    tools: [HiveToolDefinition],
    toolApprovalPolicy: HiveAgentsToolApprovalPolicy,
    compactionPolicy: HiveCompactionPolicy? = nil,
    tokenizer: (any HiveTokenizer)? = nil
  ) {
    self.modelName = modelName
    self.tools = tools
    self.toolApprovalPolicy = toolApprovalPolicy
    self.compactionPolicy = compactionPolicy
    self.tokenizer = tokenizer
  }
}

public struct HiveAgentsRuntime: Sendable {
  public let threadID: HiveThreadID
  public let runtime: HiveRuntime<HiveAgents.Schema>
  public let options: HiveRunOptions

  public init(
    threadID: HiveThreadID,
    runtime: HiveRuntime<HiveAgents.Schema>,
    options: HiveRunOptions = .init(checkpointPolicy: .everyStep)
  ) {
    self.threadID = threadID
    self.runtime = runtime
    self.options = options
  }

  public func sendUserMessage(_ text: String) async -> HiveRunHandle<HiveAgents.Schema>
  public func resumeToolApproval(
    interruptID: HiveInterruptID,
    decision: HiveAgents.ToolApprovalDecision
  ) async -> HiveRunHandle<HiveAgents.Schema>
}
```

Environment requirements (v1):
- `HiveEnvironment.modelRouter != nil` OR `HiveEnvironment.model != nil`; otherwise the attempt MUST fail before step 0 with `HiveRuntimeError.modelClientMissing`.
- `HiveEnvironment.tools != nil`; otherwise the attempt MUST fail before step 0 with `HiveRuntimeError.toolRegistryMissing`.
- If `HiveEnvironment.context.compactionPolicy != nil`:
  - `HiveEnvironment.context.tokenizer` MUST be non-nil.
  - `compactionPolicy.maxTokens` MUST be >= 1.
  - `compactionPolicy.preserveLastMessages` MUST be >= 0.
  - Otherwise, the attempt MUST fail before step 0 with `HiveRuntimeError.invalidRunOptions`.
- `HiveAgentsRuntime` defaults `options.checkpointPolicy = .everyStep`, so a `checkpointStore` is required unless callers override options (core rule in §10.0).

### 16.2 Schema (normative, v1)

SwiftAgents defines a schema type that is used by the prebuilt graph:

```swift
public extension HiveAgents {
  struct Schema: HiveSchema {
    public typealias Context = HiveAgentsContext
    public typealias Input = String
    public typealias InterruptPayload = HiveAgents.Interrupt
    public typealias ResumePayload = HiveAgents.Resume

    public static var channelSpecs: [AnyHiveChannelSpec<Self>] { get }
    public static func inputWrites(_ input: String, inputContext: HiveInputContext) throws -> [AnyHiveWrite<Self>]
  }
}
```

Channel IDs and semantics (v1):

- `messages`:
  - Type: `[HiveChatMessage]`
  - Scope: `.global`
  - Persistence: `.checkpointed`
  - Update policy: `.multi`
  - Reducer: as defined in 16.3
  - Initial: `[]`
- `pendingToolCalls`:
  - Type: `[HiveToolCall]`
  - Scope: `.global`
  - Persistence: `.checkpointed`
  - Update policy: `.single`
  - Reducer: last-write-wins
  - Initial: `[]`
- `finalAnswer`:
  - Type: `String?`
  - Scope: `.global`
  - Persistence: `.checkpointed`
  - Update policy: `.single`
  - Reducer: last-write-wins
  - Initial: `nil`
- `llmInputMessages`:
  - Type: `[HiveChatMessage]?`
  - Scope: `.global`
  - Persistence: `.untracked`
  - Update policy: `.single`
  - Reducer: last-write-wins
  - Initial: `nil`
- `currentToolCall`:
  - Type: `HiveToolCall?`
  - Scope: `.taskLocal`
  - Persistence: `.checkpointed`
  - Update policy: `.single`
  - Reducer: last-write-wins
  - Initial: `nil`

Input mapping (v1):
- `HiveAgents.Schema.inputWrites(_ text: String, inputContext: HiveInputContext)` MUST append exactly one `.user` `HiveChatMessage` to `messages` and MUST set `finalAnswer = nil`.
- The appended user message MUST have:
  - `role = .user`
  - `content = text`
  - `toolCalls = []`
  - `toolCallID = nil`
  - `op = nil`
  - deterministic `id`:
    - `id = "msg:" + sha256HexLower( ASCII("HMSG1") || runUUIDBytes || UInt32BE(inputContext.stepIndex) || ASCII("user") || UInt32BE(0) )`
    - where `runUUIDBytes` is the 16 raw RFC 4122 bytes of `inputContext.runID.rawValue`

### 16.3 Messages reducer (normative, v1; LangGraph parity)

The `messages` reducer MUST implement LangGraph-style `add_messages` behavior using `HiveChatMessage.op`:

- Normal messages have `op == nil`.
- Delete-by-id marker: `op == .remove` and `id` is the id to remove.
- Remove-all marker: `op == .removeAll` and `id == HiveAgents.removeAllMessagesID`.

Reducer algorithm (v1):
1) If `right` contains one or more remove-all markers, let `k` be the **last** index where `right[k].op == .removeAll`. Set `left = []` and set `right = Array(right[(k+1)...])`.
2) Build `merged = left` and `indexByID = first index of each id in merged`.
3) Iterate `right` in order:
   - If `m.op == .removeAll`: ignore (it is handled by step 1).
   - If `m.op == .remove`:
     - If `m.id` is not present in `indexByID`, fail the step with `HiveRuntimeError.invalidMessagesUpdate`.
     - Otherwise mark that id for deletion.
   - If `m.op == nil` (normal message):
     - If `m.id` exists in `indexByID`, replace the existing message at that index with `m` and unmark deletion for that id.
     - Else append `m` and record its index.
4) After processing, remove all ids marked for deletion.
5) The reducer output MUST contain only normal messages (`op == nil`).

Duplicate IDs (v1):
- If two normal messages with the same id appear in `right`, the later one in `right` replaces the earlier one (stable).

### 16.4 Prebuilt graph nodes (normative, v1)

Node IDs (fixed):
- `preModel` (always; built-in compaction node unless caller provides `preModel:`)
- `model`
- `routeAfterModel` (router-only)
- `tools`
- `toolExecute`
- `postModel` (optional)

Deterministic rules:
- Any unordered input (e.g., tool call collections) MUST be sorted lexicographically by UTF-8 on `(tool.name, tool.id)`.
- The tool definitions list passed to the model MUST be sorted by `HiveToolDefinition.name` lexicographically by UTF-8 bytes.

Node semantics:
- `preModel`:
  - If a caller-provided `preModel` node was passed to `makeToolUsingChatAgent`, that node runs as `preModel` and SwiftAgents imposes no additional behavior.
  - Otherwise, SwiftAgents MUST install a built-in compaction `preModel` node with this behavior:
    - Read `messages` and `llmInputMessages` from the store.
    - If `context.compactionPolicy == nil`: write `llmInputMessages = nil` and return (no compaction).
    - Else:
      - Let `policy = context.compactionPolicy!` and `tokenizer = context.tokenizer!`.
      - Let `history = messages`.
      - If `tokenizer.countTokens(history) <= policy.maxTokens`: write `llmInputMessages = nil`.
      - Else compute a trimmed list `trimmed`:
        1) Let `keepTailCount = min(policy.preserveLastMessages, history.count)`.
        2) Let `head = Array(history.dropLast(keepTailCount))` and `kept = Array(history.suffix(keepTailCount))`.
        3) While `kept.count > 1` and `tokenizer.countTokens(kept) > policy.maxTokens`, remove `kept[0]`.
        4) If `tokenizer.countTokens(kept) <= policy.maxTokens`, iterate `head` in reverse order (from newest to oldest) and greedily prepend contiguous messages:
           - For each message `m`, if `tokenizer.countTokens([m] + kept) <= policy.maxTokens`, prepend `m`; else stop.
        5) If `history.first?.role == .system` and `history.count > kept.count` and `tokenizer.countTokens([history[0]] + kept) <= policy.maxTokens`, then prepend `history[0]`.
        6) Set `trimmed = kept`.
      - Write `llmInputMessages = trimmed`.
    - The built-in `preModel` node MUST NOT mutate `messages`.
  - Static edge to `model`.
- `model`:
  - Builds `HiveChatRequest(model: context.modelName, messages: inputMessages, tools: sortedTools)` where:
    - `sortedTools = context.tools` sorted ascending by `HiveToolDefinition.name` lexicographically by UTF-8 bytes
    - `inputMessages = llmInputMessages ?? messages`
  - Selects a model client:
    - If `environment.modelRouter` is non-nil, call `route(request, hints: environment.inferenceHints)` and use the returned client.
    - Otherwise, use `environment.model!`.
  - Invokes the model using `client.stream(request)` and emits stream events using `emitStream`:
    - Emit `.modelInvocationStarted(model: request.model)` immediately before consuming the stream.
    - For each `.token(t)`, emit `.modelToken(text: t)`.
    - On `.final(response)`, capture `assistantMessage = response.message` (this MUST occur exactly once).
    - Emit `.modelInvocationFinished` after the final chunk is processed.
    - If the stream completes successfully without exactly one `.final(...)` chunk, the node MUST fail the step by throwing `HiveRuntimeError.modelStreamInvalid`.
  - Appends the assistant `HiveChatMessage` to `messages`, but MUST overwrite its `id` deterministically:
    - `assistantMessage.id = "msg:" + sha256HexLower( ASCII("HMSG1") || UTF8(run.taskID.rawValue) || 0x00 || ASCII("assistant") || UInt32BE(0) )`
  - Sets `pendingToolCalls = assistantMessage.toolCalls`.
  - If `assistantMessage.toolCalls` is empty, sets `finalAnswer = assistantMessage.content`.
  - Clears `llmInputMessages` by writing `nil`.
- `routeAfterModel` router:
  - If `pendingToolCalls` is empty → `.end`
  - Else → `.nodes([HiveNodeID(\"tools\")])`
- `tools`:
  - Let `calls = pendingToolCalls` sorted by `(name, id)`.
  - Determine whether approval is required:
    - `.never`: not required
    - `.always`: required
    - `.allowList(allowed)`: required iff `calls` contains any call where `call.name` is not in `allowed`
  - If approval is required:
    - If `run.resume?.payload` is `.toolApproval(decision: .approved)`, proceed as if approved.
    - Else if `run.resume?.payload` is `.toolApproval(decision: .rejected)`, proceed as if rejected.
    - Else:
      - Set `interrupt = HiveInterruptRequest(payload: .toolApprovalRequired(toolCalls: calls))`
      - Set `next = .nodes([HiveNodeID(\"tools\")])` (so the tools node runs again after resume)
      - MUST NOT spawn tool tasks or clear `pendingToolCalls`
  - Approved path:
    - Clear `pendingToolCalls` by writing `[]`
    - Spawn one `toolExecute` task per call in `calls`:
      - Each spawn seed MUST set task-local `currentToolCall = call`
    - Set `next = .end`
  - Rejected path:
    - Clear `pendingToolCalls` by writing `[]`
    - Append exactly one `.system` message to `messages`:
      - deterministic `id = "msg:" + sha256HexLower( ASCII("HMSG1") || UTF8(run.taskID.rawValue) || 0x00 || ASCII("system") || UInt32BE(0) )`
      - `role = .system`
      - `content = \"Tool execution rejected by user.\"`
      - `toolCalls = []`, `toolCallID = nil`, `name = nil`, `op = nil`
    - Set `next = .nodes([HiveNodeID(\"model\")])`
- `toolExecute`:
  - Reads `currentToolCall` from task-local store; if missing, fail the step with `HiveRuntimeError.missingTaskLocalValue(channelID: HiveChannelID(\"currentToolCall\"))`.
  - Emits `toolInvocationStarted(name:)` / `toolInvocationFinished(name:success:)` using `emitStream` with `metadata[\"toolCallID\"] = currentToolCall.id`.
  - Invokes `environment.tools!.invoke(currentToolCall)`:
    - On success: emit `toolInvocationFinished(name: currentToolCall.name, success: true)` and continue.
    - On failure: emit `toolInvocationFinished(name: currentToolCall.name, success: false)` and then rethrow the error (step fails; no commit).
  - Appends a `.tool` message to `messages`:
    - `id = \"tool:\" + toolCallID`
    - `role = .tool`
    - `toolCallID = toolCallID`
    - `content = result.content`
    - `toolCalls = []`
    - `op = nil`
  - Static edge to `model`.

### 16.5 Graph wiring (normative, v1)

- Start node is always `preModel` (built-in compaction node unless caller provides `preModel:`).
- `preModel -> model` (static edge)
- `model -> postModel` (static edge, if `postModel` exists)
- `model -> routeAfterModel` (static edge, if `postModel` does not exist)
- `postModel -> routeAfterModel` (static edge)
- `routeAfterModel` has a builder router implementing 16.4 routing.
- `toolExecute -> model` (static edge)

### 16.6 Facade behavior (normative, v1)

- `HiveAgentsRuntime.sendUserMessage(text)` MUST call `HiveRuntime.run(threadID:input:options:)` with `threadID = self.threadID`, `input = text`, and `options = self.options`.
- `HiveAgentsRuntime.resumeToolApproval(interruptID:decision:)` MUST call `HiveRuntime.resume(threadID:interruptID:payload:options:)` with `threadID = self.threadID`, `payload = .toolApproval(decision: decision)`, and `options = self.options`.

---

## 17) Testing requirements

Hive v1 is implemented TDD-first using the Swift Testing Framework. Every MUST rule that changes observable behavior must be pinned by at least one deterministic test.

### 17.1 Golden digests (normative fixtures)

These golden values are derived from the hashing/canonical-byte rules in this spec and MUST be asserted in tests to prevent accidental spec drift.

```txt
empty_taskLocalFingerprint (HLF1 + entryCount=0):
3b54d1bf22aea64fa72d74e8bca1e504ea5f40f832e6bbf952ba79015becff2f

schemaVersion_example (HSV1) for a schema with:
  - channel `a`: typeID="Swift.Int", scope=global, persistence=checkpointed, updatePolicy=single, codecID="int.v1"
  - channel `b`: typeID="Swift.String", scope=global, persistence=untracked, updatePolicy=single, codecID=""
76a2aa861605de05dad8d5c61c87aa45b56fa74a32c5986397e5cf025866b892

graphVersion_example (HGV1) for a graph with:
  - start=["A"], nodes=["A"], routers=[], staticEdges=[], joinEdges=[], outputProjection=fullStore
6614009a9f5308c8dca81acf8ed7ee4e22a3d946e77a9eb864c70db09d1b993d
```

### 17.2 Test matrix (requirements → tests → deterministic oracle)

| Area | Requirement (spec) | Swift Testing test(s) | Deterministic oracle |
|---|---|---|---|
| Versioning | `schemaVersion` canonical bytes (14.3) | `testSchemaVersion_GoldenHSV1()` | `compiled.schemaVersion == 76a2...b892` |
| Versioning | `graphVersion` canonical bytes includes start + routers (14.3) | `testGraphVersion_GoldenHGV1()` | `compiled.graphVersion == 6614...993d` |
| Compilation | Duplicate channel IDs rejected (6.5, 9.0) | `testCompile_DuplicateChannelID_Fails()` | throws `HiveCompilationError.duplicateChannelID` for the smallest duplicated channel ID |
| Compilation | `.taskLocal` cannot be `.untracked` (6.5, 9.0) | `testCompile_TaskLocalUntracked_Fails()` | throws `HiveCompilationError.invalidTaskLocalUntracked(channelID:)` |
| Compilation | Reserved `+`/`:` in node IDs rejected (9.1, 9.3) | `testCompile_NodeIDReservedJoinCharacters_Fails()` | throws `HiveCompilationError.invalidNodeIDContainsReservedJoinCharacters(nodeID:)` |
| Store | `initialCache` evaluated once, lexicographic order (7.1) | `testInitialCache_EvaluatedOnceInLexOrder()` | recorded evaluation order equals sorted channel IDs; count==1 per channel |
| Store | Untracked reset on resume/load (7.2) | `testUntrackedChannels_ResetOnCheckpointLoad()` | value differs during run, is absent in checkpoint, becomes initial after resume |
| Fingerprint | Empty task-local fingerprint (7.3) | `testTaskLocalFingerprint_EmptyGolden()` | computed digest equals `3b54...ff2f` |
| Reducers | `.single` global updatePolicy enforced across tasks (8) | `testUpdatePolicySingle_GlobalViolatesAcrossTasks_FailsNoCommit()` | throws `HiveRuntimeError.updatePolicyViolation`; global store unchanged; no checkpoint for that step |
| Reducers | `.single` taskLocal updatePolicy enforced per task (8) | `testUpdatePolicySingle_TaskLocalPerTask_AllowsAcrossTasks()` | run completes (no error) when 2 different tasks each write once |
| Reducers | Reducer throw aborts commit (8, 10.4) | `testReducerThrows_AbortsStep_NoCommit()` | outcome throws; no writeApplied/checkpointSaved for the step; global store unchanged |
| Routing | Fresh read isolation `preStepGlobal + thisTaskWrites` (10.4) | `testRouterFreshRead_SeesOwnWriteNotOthers()` | next frontier contains node IDs expected per task’s own write; order stable |
| Routing | Router fresh-read view construction errors abort step (10.4) | `testRouterFreshRead_ErrorAbortsStep()` | outcome throws the first router-view construction error (smallest `taskOrdinal`); no commit-scoped events (`writeApplied`, `checkpointSaved`, `stepFinished`) |
| Routing | Router `.useGraphEdges` falls back to static edges (10.4) | `testRouterReturnUseGraphEdges_FallsBackToStaticEdges()` | next frontier equals static-edge order for that node |
| Ordering | Global write order `(taskOrdinal, writeEmissionIndex)` (10.4) | `testGlobalWriteOrdering_DeterministicUnderRandomCompletion()` | final channel value matches reducer applied in that order (not completion order) |
| Dedupe | Dedupe applies to graph seeds only (10.4) | `testDedupe_GraphSeedsOnly()` | duplicate graph seeds collapse to 1; duplicate spawn seeds remain |
| Frontier | Next frontier order = graph seeds then spawn seeds (10.4) | `testFrontierOrdering_GraphBeforeSpawn()` | `taskStarted` events show graph tasks have lower ordinals than spawn tasks |
| Join | Parent contributions from all tasks (graph + spawn) (9.1, 10.4) | `testJoinBarrier_IncludesSpawnParents()` | join fires when parents execute as spawn tasks; target scheduled in next step |
| Join | Target “early run” does not clear partial barrier (9.1) | `testJoinBarrier_TargetRunsEarly_DoesNotReset()` | target runs once via direct edge; later runs again via join after all parents fire |
| Join | Consume only when available (9.1, 10.4) | `testJoinBarrier_ConsumeOnlyWhenAvailable()` | barrier seenParents unchanged by early target run; resets when target runs with barrier available |
| Writes | Unknown channel write fails no commit (10.4) | `testUnknownChannelWrite_FailsNoCommit()` | throws `HiveRuntimeError.unknownChannelID`; no `writeApplied`/`stepFinished` for that step; global store unchanged |
| Failures | Multiple task failures choose smallest `taskOrdinal` error (11.4, 13.5) | `testMultipleTaskFailures_ThrowsEarliestOrdinalError()` | outcome throws the error from ordinal 0; events include `taskFailed` for all failed tasks |
| Failures | Commit-time failure precedence is deterministic (10.4) | `testCommitFailurePrecedence_UnknownChannelBeatsUpdatePolicy()` | outcome throws `unknownChannelID` (first by scan order), not `updatePolicyViolation` |
| Resume | Resume clears interruption only after first committed step (12.3) | `testResume_FirstCommitClearsInterruption()` | after first resumed step commits, a subsequent `run(...)` does not fail with `interruptPending` |
| Resume | Resume cancelled before first commit keeps interruption pending (12.3) | `testResume_CancelBeforeFirstCommit_KeepsInterruption()` | after cancelling resume before any commit, a subsequent `run(...)` fails with `interruptPending` |
| Checkpoint | Snapshot includes frontier provenance + task-local overlays (14.1–14.2) | `testCheckpoint_PersistsFrontierOrderAndProvenance()` | checkpoint.frontier order matches runtime; provenance fields match expected |
| Checkpoint | `stepIndex` meaning is “next step to execute” (14.1) | `testCheckpoint_StepIndexIsNextStep()` | after committing step N, saved checkpoint.stepIndex == N+1 |
| Checkpoint | Checkpoint ID derivation `HCP1` (14.2) | `testCheckpointID_DerivedFromRunIDAndStepIndex()` | `checkpoint.id.rawValue == sha256(\"HCP1\"||runUUIDBytes||UInt32BE(stepIndex))` |
| Checkpoint | Checkpoint decode failure fails before step 0 (14.2) | `testCheckpointDecodeFailure_FailsBeforeStep0()` | throws `HiveRuntimeError.checkpointDecodeFailed` and no `stepStarted` emitted |
| Checkpoint | Checkpoint structural validation fails before step 0 (14.2) | `testCheckpointCorrupt_JoinBarrierKeysMismatch_FailsBeforeStep0()` | throws `HiveRuntimeError.checkpointCorrupt(field: \"joinBarrierSeenByJoinID\", ...)` |
| Checkpoint | Checkpoint save failure aborts commit (10.4, 11.1) | `testCheckpointSaveFailure_AbortsCommit()` | outcome throws; no `checkpointSaved`/`stepFinished` for that step; global store unchanged |
| Checkpoint | Checkpoint encode failure aborts commit deterministically (14.2) | `testCheckpointEncodeFailure_AbortsCommitDeterministically()` | throws `HiveRuntimeError.checkpointEncodeFailed` for first failing channel in spec order; no commit-scoped events |
| Fingerprint | Fingerprint encode failure deterministic (7.3) | `testTaskLocalFingerprintEncodeFailure_Deterministic()` | throws `HiveRuntimeError.taskLocalFingerprintEncodeFailed` for first failing channel in spec order |
| Checkpoint | Checkpoint load I/O errors propagate before step 0 (10.0) | `testCheckpointLoadThrows_FailsBeforeStep0()` | outcome throws store error; no `stepStarted` emitted |
| Resume | Version mismatch fails before step 0 (14.3, 10.0) | `testResume_VersionMismatchFailsBeforeStep0()` | `HiveRuntimeError.checkpointVersionMismatch` and no `stepStarted` emitted |
| Interrupt | Interrupt selection by smallest `taskOrdinal` (12.2) | `testInterrupt_SelectsEarliestTaskOrdinal()` | chosen interrupt payload equals earliest task’s request; later ignored |
| Interrupt | Interrupt ID derived from taskID (12.2) | `testInterruptID_DerivedFromTaskID()` | `interruptID == sha256HexLower(\"HINT1\"||taskID.rawValueUTF8)` |
| Resume | Resume sets runContext.resume only first step (12.3) | `testResume_VisibleOnlyFirstStep()` | node writes “saw resume” only in first resumed step; later steps see nil |
| Events | Deterministic sequencing of deterministic events (13.2) | `testEventSequence_DeterministicEventsOrder()` | exact ordered list of kinds matches spec sequence (runStarted, stepStarted, taskStarted…, writeApplied…, stepFinished, runFinished) |
| Events | Failed steps don’t emit commit/finish events (13.5) | `testFailedStep_NoStepFinishedOrWriteApplied()` | on commit failure, stream ends with error after task events; no `writeApplied`/`checkpointSaved`/`stepFinished` for that step |
| Debug | `debugPayloads` includes full payload metadata (13.3) | `testDebugPayloads_WriteAppliedMetadata()` | when enabled, `writeApplied.metadata[\"payloadEncoding\"]` and `payload` exist; when disabled, they do not |
| Streaming | Stream events live vs buffered mode (13.2) | `testDeterministicTokenStreaming_BuffersStreamEvents()` | with deterministicTokenStreaming=true, stream events are buffered and emitted after compute in taskOrdinal order, and appear before any `taskFinished`/`taskFailed` events |
| Backpressure | Droppable token drop/coalesce policy (13.4) | `testBackpressure_ModelTokensCoalesceAndDropDeterministically()` | coalesced token text equals concatenation; dropped counts match; `streamBackpressure` emitted before `stepFinished` |
| External | `applyExternalWrites` synthetic step increments stepIndex and keeps frontier (10.0) | `testApplyExternalWrites_IncrementsStepIndex_KeepsFrontier()` | stepIndex increments by 1; frontier unchanged; checkpoint saved regardless of policy |
| External | External writes reject taskLocal writes (10.0) | `testApplyExternalWrites_RejectsTaskLocalWrites()` | fails with `HiveRuntimeError.taskLocalWriteNotAllowed` before commit |
| Limits | `maxSteps` out-of-steps behavior (10.4) | `testOutOfSteps_StopsWithoutExecutingAnotherStep()` | outcome is `.outOfSteps`; no extra `stepStarted` beyond limit |
| HiveAgents | Messages reducer remove-all uses last marker (16.3) | `testAgentsMessagesReducer_RemoveAll_UsesLastMarker()` | resulting messages equal updates after last removeAll marker |
| HiveAgents | Built-in compaction trims via `llmInputMessages` (16.4) | `testAgentsCompaction_TrimsToBudget_WithoutMutatingMessages()` | `messages` unchanged; `llmInputMessages` equals expected trimmed list |
| HiveAgents | Model stream must include final chunk (15.2, 16.4) | `testAgentsModelStream_MissingFinalFails()` | fails with `HiveRuntimeError.modelStreamInvalid` |
| HiveAgents | Tools approval interrupt/resume flow (16.4) | `testAgentsToolApproval_InterruptsAndResumes()` | interrupt payload lists sorted tool calls; approved runs tools; rejected appends exact system message |
| HiveAgents | Tool message ID is deterministic `tool:<id>` (16.4) | `testAgentsToolExecute_AppendsToolMessageWithDeterministicID()` | appended tool message id equals `tool:` + toolCallID |

---

## 18) Definition of done

- Deterministic runs and traces with golden tests
- Checkpoint/resume identical results to uninterrupted run
- Send/fan-out and join edges working
- HiveAgents prebuilt graph with tool approval and compaction
- swift test passes for all targets
