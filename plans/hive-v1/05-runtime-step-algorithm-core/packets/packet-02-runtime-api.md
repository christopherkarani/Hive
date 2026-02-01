Prompt:
You are a senior Swift 6.2 engineer. Implement the public runtime API surface and environment/configuration types for Plan 05. Do NOT edit any plan documents. Follow spec §10.0, with fail-fast stubs for resume/external-writes/checkpoints.

Goal:
Provide the `HiveRuntime` public API shape and supporting types (`HiveRunOptions`, `HiveEnvironment`, clock/logger abstractions, run handles/outcomes). Enforce validation rules and thread serialization (single-writer per `HiveThreadID`).

Task BreakDown
- Inspect existing runtime scaffolding under `libs/hive/Sources/HiveCore/Runtime/` for patterns and dependencies.
- Implement/extend:
  - `HiveRunOptions` with §10.0 defaults and validation (maxSteps/maxConcurrentTasks/eventBufferCapacity, projection normalization).
  - `HiveClock` and `HiveLogger` protocols or types as needed by `HiveEnvironment`.
  - `HiveEnvironment` with optional placeholders for model/tools until Plan 10.
  - `HiveRunHandle`, `HiveRunOutcome`, `HiveRunOutput`, `HiveProjectedChannelValue`, `HiveRunContext` (resume visibility placeholder only).
  - `AnyHiveCheckpointStore` wrapper type (even if unused now).
- Implement `HiveRuntime` methods:
  - `run(threadID:input:options:)` fully in-memory.
  - `resume(...)` and `applyExternalWrites(...)` as fail-fast stubs (do not partially implement).
  - `getLatestStore(threadID:)` and `getLatestCheckpoint(threadID:)` (checkpoint returns nil until Plan 09).
- Enforce per-thread serialization: same `threadID` operations are queued; different `threadID`s may run concurrently.
- Add Swift Testing coverage for options validation and projection normalization; add a minimal concurrency test for per-thread serialization if feasible without the step engine.
