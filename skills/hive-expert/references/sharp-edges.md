# Sharp Edges (Read This Before You Debug)

## Schema + Channels
- Channel IDs must be unique per schema.
- `.taskLocal` channels:
  - MUST be `.checkpointed` (untracked task-local is invalid).
  - MUST have a codec path (explicit codec or the default JSON codec, depending on how you declare it).
- `.global` channels:
  - MAY be `.untracked` (no codec needed).
  - MUST have a codec when `persistence == .checkpointed`.
- `HiveUpdatePolicy.single`:
  - Violated when multiple writes to the same channel occur in a step (depends on channel scope; task-local writes are per-task).
- Reducers must be deterministic and should not depend on non-deterministic input (timestamps, random, unordered collections).

## Runtime Semantics
- Step commit is all-or-nothing:
  - Any commit-phase error aborts the step; there is no partial commit.
- Per-thread serialization:
  - Concurrent attempts on a single `HiveThreadID` are queued.
- Interrupt selection:
  - Deterministic choice: smallest task ordinal in the step.
  - If an interrupt is pending, new runs may be blocked until resume.

## Events and Streaming
- `eventBufferCapacity`:
  - On pressure, Hive drops/coalesces **model token** and **custom debug** stream events.
  - Non-droppable events can still block producers (so “capacity too small” can become a performance issue).
- `deterministicTokenStreaming`:
  - Buffers per-task stream events and emits them after task completion in deterministic order.
  - Great for golden tests; changes the “live feel” of streaming.

## Model Client Contract
- `HiveModelClient.stream(_:)` MUST:
  - Emit exactly one `.final(...)` chunk on success.
  - Emit it last (no token after final).
  - Match `complete(_:)` semantics.

## Checkpoints
- Loading a checkpoint:
  - Validates schema version, graph version, channel fingerprints, join IDs, etc.
  - Resets untracked channels to initial values.

