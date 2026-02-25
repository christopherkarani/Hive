# Runtime Execution

Understand the HiveRuntime actor, superstep execution loop, event streaming, and run options.

## Overview

``HiveRuntime`` is the central execution engine — a Swift `actor` that ensures data-race-free state management. It executes compiled graphs using the BSP superstep model, providing rich event streams and configurable execution options.

## HiveRuntime

```swift
public actor HiveRuntime<Schema: HiveSchema>: Sendable {
    public init(
        graph: CompiledHiveGraph<Schema>,
        environment: HiveEnvironment<Schema>
    ) throws

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

    public func fork(
        threadID sourceThreadID: HiveThreadID,
        to newThreadID: HiveThreadID,
        from checkpointID: HiveCheckpointID? = nil,
        options: HiveRunOptions? = nil
    ) async throws -> HiveForkResult<Schema>

    public func getForkEventHistory(
        limit: Int? = nil
    ) -> [HiveEvent]

    public func getState(
        threadID: HiveThreadID
    ) async throws -> HiveRuntimeStateSnapshot<Schema>?

    public func getLatestStore(
        threadID: HiveThreadID
    ) -> HiveGlobalStore<Schema>?
}
```

## HiveEnvironment

``HiveEnvironment`` is the dependency injection container provided to the runtime:

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

## HiveRunHandle

Every entry point returns a ``HiveRunHandle`` with both an event stream and a terminal outcome:

```swift
public struct HiveRunHandle<Schema: HiveSchema>: Sendable {
    public let runID: HiveRunID
    public let events: AsyncThrowingStream<HiveEvent, Error>
    public let outcome: Task<HiveRunOutcome<Schema>, Error>
}
```

`runID` is the canonical identifier for that handle's execution lineage. If a run cold-starts by restoring
checkpoint state, the restored state is rebound to this `runID` so event IDs, task IDs, and newly saved
checkpoints remain consistent for the active handle.

`fork` is intentionally different: it is an atomic state-branch operation that returns ``HiveForkResult``
after cloning (and optionally persisting) target state. It does not execute steps.

## Fork guarantees

- Source state is decoded from a single checkpoint (explicit ID or latest).
- Target receives an independent lineage (new run ID + optional fork lineage metadata).
- Global store, frontier/deferred frontier, join barrier state, interruption, channel versions,
  and versionsSeen are preserved.
- Fail-closed behavior: no partial target state commit on fork failure.

Fork lifecycle observability is emitted as runtime events:
- `forkStarted`
- `forkCompleted`
- `forkFailed`

## Run outcomes

```swift
public enum HiveRunOutcome<Schema: HiveSchema>: Sendable {
    case finished(output: HiveRunOutput<Schema>, checkpointID: HiveCheckpointID?)
    case interrupted(interruption: HiveInterruption<Schema>)
    case cancelled(output:, checkpointID:)
    case outOfSteps(maxSteps:, output:, checkpointID:)
}
```

## The superstep loop

Each superstep has three phases:

### Phase 1: Concurrent node execution

All frontier nodes execute concurrently within a `TaskGroup`, bounded by `maxConcurrentTasks`. Each node reads from a pre-step snapshot — no node sees another's writes from the same step.

### Phase 2: Atomic commit

Writes are collected, ordered by `(taskOrdinal, emissionIndex)`, and reduced through each channel's reducer. Ephemeral channels reset to initial values.

### Phase 3: Frontier scheduling

Routers run on post-commit state. Join barriers update. The next frontier is assembled, deduplicated, and optionally filtered by trigger conditions.

### Run loop pseudocode

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

## Frontier computation

Sources for the next frontier:

1. **Static edges** — `graph.staticEdgesByFrom[nodeID]`
2. **Routers** — dynamic routing on post-commit state
3. **Node output `next`** — `.end`, `.nodes([...])`, or `.useGraphEdges`
4. **Spawn seeds** — fan-out tasks with task-local state
5. **Join barriers** — fire when all parents complete

Seeds are deduplicated by `(nodeID, taskLocalFingerprint)`.

## Event streaming

``HiveEvent`` covers the full lifecycle:

| Category | Events |
|----------|--------|
| Run lifecycle | `runStarted`, `runFinished`, `runInterrupted`, `runResumed`, `runCancelled(cause)` |
| Superstep | `stepStarted`, `stepFinished` |
| Task | `taskStarted`, `taskFinished`, `taskFailed` |
| Writes | `writeApplied` |
| Checkpoint | `checkpointSaved`, `checkpointLoaded` |
| Model | `modelInvocationStarted`, `modelToken`, `modelInvocationFinished` |
| Tools | `toolInvocationStarted`, `toolInvocationFinished` |

### Streaming modes

Configure via ``HiveRunOptions``:

- `.events` — standard events only
- `.values` — full store snapshots after each step
- `.updates` — only written channels
- `.combined` — both values and updates

## Run options

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

## Retry policies

``HiveRetryPolicy`` supports exponential backoff:

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

Delay formula: `min(maxNanoseconds, floor(initialNanoseconds * pow(factor, attempt - 1)))`
