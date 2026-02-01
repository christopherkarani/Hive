# Plan 05 — Runtime public API + core step algorithm (no checkpointing yet)

## Goal

Implement the `HiveRuntime` public API surface and the deterministic superstep engine core:

- runtime configuration (`HiveRunOptions`, `HiveEnvironment`, clock/logger abstractions)
- thread serialization model (single-writer per `HiveThreadID`)
- task model (`HiveTaskID`, `HiveTask`, provenance) and task ordinal assignment
- step algorithm compute + deterministic commit (writes, routing, join contributions, next frontier)

This plan targets the “vertical slice” of execution and determinism, but intentionally defers **checkpoint I/O** (Plan 09 wires checkpoint stores) and **resume/external-writes semantics** (Plan 08). This plan SHOULD still define the full §10.0 API surface so downstream plans don’t churn signatures.

## Spec anchors

- `HIVE_SPEC.md` §10.0–§10.4 (runtime execution)
- `HIVE_SPEC.md` §9.1 join semantics (commit-time barrier consume/contribute rules)
- `HIVE_SPEC.md` §17.2 tests for ordering/routing/join/writes/frontier

## Deliverables

- `libs/hive/Sources/HiveCore/Runtime/`:
  - `HiveRuntime.swift`
  - `HiveRunOptions.swift`
  - `HiveEnvironment.swift` (clock/logger protocols can live here)
  - `HiveRunHandle.swift` (outcome + events; events wiring can be stubbed until Plan 06)
  - `HiveRunOutcome.swift` / `HiveRunOutput.swift`
  - `HiveProjectedChannelValue.swift`
  - `HiveRunContext.swift` (context + resume visibility placeholder)
- `libs/hive/Sources/HiveCore/Graph/` additions:
  - `HiveTaskID.swift`
  - `HiveTask.swift`
  - `HiveTaskProvenance.swift`
- `HiveRuntime` API shape matches §10.0 (even if some methods are “fail-fast stubs” until later plans):
  - `run(threadID:input:options:)`
  - `resume(threadID:interruptID:payload:options:)` (Plan 08)
  - `applyExternalWrites(threadID:writes:options:)` (Plan 08)
  - `getLatestStore(threadID:)`
  - `getLatestCheckpoint(threadID:)` (Plan 09)
- Deterministic step algorithm implementation sufficient to satisfy (minimum) these tests from §17.2:
  - `testRouterFreshRead_SeesOwnWriteNotOthers()`
  - `testRouterFreshRead_ErrorAbortsStep()`
  - `testRouterReturnUseGraphEdges_FallsBackToStaticEdges()`
  - `testGlobalWriteOrdering_DeterministicUnderRandomCompletion()`
  - `testDedupe_GraphSeedsOnly()`
  - `testFrontierOrdering_GraphBeforeSpawn()`
  - `testJoinBarrier_IncludesSpawnParents()`
  - `testJoinBarrier_TargetRunsEarly_DoesNotReset()`
  - `testJoinBarrier_ConsumeOnlyWhenAvailable()`
  - `testUnknownChannelWrite_FailsNoCommit()`

## Work breakdown

1. Implement core run identifiers (`HiveThreadID`, `HiveRunID`, `HiveRunAttemptID`) and stable ordering rules.
2. Implement `HiveTaskID` derivation per spec (§10.3 / checkpoint resume recomputation).
3. Implement the public runtime surface from §10.0:
   - `HiveRunOptions` with the spec default values
     - include §10.0 validation rules (e.g., `maxSteps >= 0`, `maxConcurrentTasks >= 1`, `eventBufferCapacity >= 1`, and `.every(steps:)` requires `steps >= 1`)
     - normalize `.channels(ids)` projection override to unique + lexicographically sorted (per §10.0)
   - `HiveClock` / `HiveLogger`
   - `AnyHiveCheckpointStore` wrapper type (even if checkpoint policy is `.disabled` in this phase)
   - `HiveEnvironment` fields (model/tools can be optional placeholders until Plan 10)
   - `HiveRunHandle` / `HiveRunOutcome` / `HiveRunOutput` / `HiveProjectedChannelValue`
   - implement the §10.0 thread serialization contract: operations for the same `threadID` are queued (not concurrent), while different `threadID`s may progress concurrently.
   - scope decision for Plan 05:
     - `run(...)` is fully implemented (in-memory baseline only; checkpoint load/save deferred)
     - `resume(...)` / `applyExternalWrites(...)` may be implemented as fail-fast stubs until Plan 08 (do not “partially implement” spec behavior here)
     - `getLatestCheckpoint(...)` may return `nil` until Plan 09 wires checkpoint I/O
4. Implement step algorithm skeleton:
   - maintain per-thread in-memory state per §10.0 (runID, stepIndex, global snapshot, frontier, join progress, interruption, latestCheckpointID)
   - frontier seeding: if frontier is empty at attempt start, seed from `graph.start` preserving order
   - apply `Schema.inputWrites(input, inputContext: ...)` as synthetic writes before the first executed step
   - (Plan 06 will wire full events) structure the engine so the attempt can “fail before step 0” (after `runStarted`, before any `stepStarted`) per §10.0/§10.2
   - run tasks concurrently but buffer outputs deterministically by `taskOrdinal`
   - deterministic commit order for writes
   - build per-task “fresh read” views for routers (preStepGlobal + thisTaskWrites)
     - router evaluation happens after commit-time validations succeed; router-view construction errors are commit-time failures (per §10.4)
   - compute next frontier ordering (graph seeds then spawn seeds)
   - stop conditions: finish when the next frontier is empty (maxSteps/out-of-steps semantics are implemented in Plan 07)
5. Implement join barrier consume/contribute rules in commit phase.
6. Implement “no commit on validation failure” behavior for unknown channels (and later: updatePolicy, reducer throws, etc.).
7. Add the targeted tests above to pin behavior.

## Acceptance criteria

- Core runtime tests pass and demonstrate determinism under randomized task completion timing.
- Failures during commit do not mutate global state.
- Plan 05 does not introduce “partial” resume/external-writes/checkpoint behavior that would conflict with §10.0; those semantics land in Plans 08–09.
