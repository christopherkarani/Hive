# Runtime Semantics (Deep Dive)

## Superstep Contract (High Level)
For each step:
1. Emit `stepStarted`.
1. Execute each task in the frontier (bounded concurrency), emitting:
   - `taskStarted` / `taskFinished` / `taskFailed`
   - stream events (`modelToken`, tool events, `customDebug`) via node emitters
1. Commit (all-or-nothing):
   - validate all writes against schema + types
   - enforce update policies
   - merge writes with reducers
   - compute next frontier (edges/routers/spawn/join barriers)
1. Optionally save a checkpoint (step-synchronous).
1. Emit `stepFinished`.

If commit fails, the step is aborted and there is no partial application of writes.

## Determinism and Ordering
- Tasks have deterministic ordinals; any ordering-sensitive logic should use those ordinals.
- Join IDs are canonicalized (sorted parent IDs).
- Dictionary merge reducer processes keys in ascending UTF-8 order.

## Routers
- Routers are synchronous and deterministic (`HiveRouter` is not async).
- Router reads are from a `HiveStoreView` (global + task-local overlay + initial cache).

## External Writes
`applyExternalWrites(threadID:writes:options:)` applies writes in a synthetic step, using the same validation and reducer rules.

## Retries and Cancellation (Design Implications)
- Retries are deterministic (no jitter); use injected `HiveClock` to control timing.
- Cancellation during a step aborts commit; design nodes to be idempotent where possible.

## Events + Backpressure
- Events are emitted via an internal stream controller with a bounded buffer.
- Under backpressure, Hive may drop/coalesce:
  - `.modelToken(...)`
  - `.customDebug(...)`
- Non-droppable lifecycle events can still block producers if the consumer is slow.
- If `deterministicTokenStreaming` is enabled, stream events may be buffered to preserve stable ordering (better for golden tests, worse for live UX).

