# Plan 07 — Errors, retries, cancellation, maxSteps

## Goal

Implement error taxonomy and control-flow semantics:

- `HiveRuntimeError` cases (and any supporting errors) per spec
- retry policy validation + deterministic exponential backoff (no jitter)
- step atomicity rules and deterministic error selection when multiple failures occur
- cancellation semantics (between steps and during a step)
- maxSteps/out-of-steps behavior

## Spec anchors

- `HIVE_SPEC.md` §11.0–§11.4 (all)
- `HIVE_SPEC.md` §10.4 commit-time validation precedence (referenced by tests)
- `HIVE_SPEC.md` §13.2 + §13.5 where errors/cancellation affect event sequencing/termination
- Required tests in §17.2:
  - `testMultipleTaskFailures_ThrowsEarliestOrdinalError()`
  - `testCommitFailurePrecedence_UnknownChannelBeatsUpdatePolicy()`
  - `testUpdatePolicySingle_GlobalViolatesAcrossTasks_FailsNoCommit()`
  - `testUpdatePolicySingle_TaskLocalPerTask_AllowsAcrossTasks()`
  - `testReducerThrows_AbortsStep_NoCommit()`
  - `testOutOfSteps_StopsWithoutExecutingAnotherStep()`
  - plus any retry/cancellation tests you add to lock behavior

## Deliverables

- `libs/hive/Sources/HiveCore/Errors/HiveRuntimeError.swift`
- `HiveRetryPolicy` validation integrated into runtime “before step 0” validation
- Runtime support for retries and cancellation semantics as specified
- Tests pinning deterministic selection and “no commit on failure/cancel”

## Work breakdown

1. Add `HiveRuntimeError` enum and ensure it’s used consistently.
2. Implement retry attempt loop:
   - discard outputs from failed attempts
   - deterministic backoff using injected clock
   - validate retry policy parameters before step 0 (smallest nodeID on multiple invalids)
   - treat `HiveClock.sleep(...)` throwing `CancellationError` as cancellation (not an error), per §11.2/§11.3
3. Implement step atomicity: any failure (task or commit validation or required checkpoint save later) prevents commit.
4. Implement cancellation:
   - cancellation is observed via `Task.isCancelled` and is not an error (must not terminate events by throwing)
   - between steps: if observed before emitting `stepStarted`, stop immediately and emit only `runCancelled` as the terminal event (no new step begins)
   - during step: if observed after `stepStarted` and before commit:
     - cancel all in-flight node tasks
     - emit `taskFailed` for **every** frontier task in ascending `taskOrdinal` as if failed with `CancellationError()`
     - do not commit (no writes/barriers/frontier/checkpoint)
     - do not emit commit-scoped events (`writeApplied`, `checkpointSaved`, `streamBackpressure`, `stepFinished`)
     - emit `runCancelled` as the terminal event
5. Implement maxSteps/out-of-steps semantics.
6. Add missing tests to lock retry/cancellation semantics not enumerated in §17.2:
   - cancellation between steps does not emit an extra `stepStarted`
   - cancellation during a step emits `taskFailed` for all tasks and does not commit or emit `stepFinished`
   - deterministic retry backoff sleep schedule uses the injected clock and no jitter

## Acceptance criteria

- Errors are thrown at the timing required by the spec (before step 0 vs during commit).
- Tests verify deterministic selection when multiple failures occur.
