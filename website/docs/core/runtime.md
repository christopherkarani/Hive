---
sidebar_position: 4
title: Runtime Engine
description: HiveRuntime actor, superstep execution, event streaming, retry policies, and determinism guarantees.
---

# Runtime Engine

## HiveRuntime Actor

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

## HiveEnvironment

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

## HiveRunHandle

Every entry point returns a handle with both event stream and terminal outcome:

```swift
public struct HiveRunHandle<Schema: HiveSchema>: Sendable {
    public let runID: HiveRunID
    public let events: AsyncThrowingStream<HiveEvent, Error>
    public let outcome: Task<HiveRunOutcome<Schema>, Error>
}
```

## HiveRunOutcome

```swift
public enum HiveRunOutcome<Schema: HiveSchema>: Sendable {
    case finished(output: HiveRunOutput<Schema>, checkpointID: HiveCheckpointID?)
    case interrupted(interruption: HiveInterruption<Schema>)
    case cancelled(output:, checkpointID:)
    case outOfSteps(maxSteps:, output:, checkpointID:)
}
```

## Superstep Execution Loop (BSP Model)

Each superstep has three phases:

### Phase 1: Concurrent Node Execution
All frontier nodes execute concurrently within a `TaskGroup`, bounded by `maxConcurrentTasks`. Each node reads from a pre-step snapshot — no node sees another's writes from the same step.

### Phase 2: Atomic Commit
Writes are collected, ordered by `(taskOrdinal, emissionIndex)`, and reduced through each channel's reducer. Ephemeral channels reset to initial values.

### Phase 3: Frontier Scheduling
Routers run on post-commit state. Join barriers update. The next frontier is assembled, deduplicated, and optionally filtered by trigger conditions.

## The Run Loop

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

## Frontier Computation

Sources for the next frontier:
1. **Static edges** — `graph.staticEdgesByFrom[nodeID]`
2. **Routers** — dynamic routing on post-commit state
3. **Node output `next`** — `.end`, `.nodes([...])`, or `.useGraphEdges`
4. **Spawn seeds** — fan-out tasks with task-local state
5. **Join barriers** — fire when all parents complete

Seeds are deduplicated by `(nodeID, taskLocalFingerprint)`.

## Event Streaming

| Category | Events |
|----------|--------|
| Run lifecycle | `runStarted`, `runFinished`, `runInterrupted`, `runResumed`, `runCancelled` |
| Superstep | `stepStarted(stepIndex, frontierCount)`, `stepFinished(stepIndex, nextFrontierCount)` |
| Task | `taskStarted(node, taskID)`, `taskFinished(node, taskID)`, `taskFailed(node, taskID, error)` |
| Writes | `writeApplied(channelID, payloadHash)` |
| Checkpoint | `checkpointSaved(id)`, `checkpointLoaded(id)` |
| Model | `modelInvocationStarted`, `modelToken`, `modelInvocationFinished` |
| Tools | `toolInvocationStarted`, `toolInvocationFinished` |

### Streaming Modes

Via `HiveRunOptions`:
- `.events` — standard events only
- `.values` — full store snapshots after each step
- `.updates` — only written channels
- `.combined` — both

### Event Stream Views

Typed, filtered sub-streams:

```swift
let views = HiveEventStreamViews(handle.events)
for try await step in views.steps() { /* HiveStepEvent */ }
for try await task in views.tasks() { /* HiveTaskEvent */ }
```

## Retry Policies

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

## Run Options

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

## Determinism Guarantees

1. **Lexicographic ordering** of node execution by `HiveNodeID`
2. **Deterministic task IDs** — SHA-256 of `(runID, stepIndex, nodeID, ordinal, fingerprint)`
3. **Deterministic interrupt IDs** — SHA-256 of `"HINT1" + taskID`
4. **Deterministic checkpoint IDs** — SHA-256 of `"HCP1" + runID + stepIndex`
5. **Atomic superstep commits** — all writes apply together, sorted by `(taskOrdinal, emissionIndex)`
6. **Sorted channel iteration** — `registry.sortedChannelSpecs` ensures consistent processing
7. **Deterministic token streaming** — buffer model tokens per-task, replay in ordinal order
