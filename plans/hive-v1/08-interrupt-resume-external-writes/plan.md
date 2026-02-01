# Plan 08 — Interrupt/resume and external writes

## Goal

Implement:

- interrupt request/selection rules and deterministic interrupt ID derivation
- resume validation + resume visibility rules
- clearing interruption only after the first successfully committed resumed step
- `applyExternalWrites(...)` semantics (synthetic step increments stepIndex; keeps frontier)

This plan focuses on interrupt/resume control-flow and `applyExternalWrites(...)`. Full checkpoint I/O + decode/validation is implemented in Plan 09.

## Spec anchors

- `HIVE_SPEC.md` §12.1–§12.3 (interrupt/resume)
- `HIVE_SPEC.md` §10.0 (external writes API + stepIndex behavior)
- `HIVE_SPEC.md` §13.2 (event sequencing for synthetic external-write steps)
- Required tests in §17.2:
  - `testInterrupt_SelectsEarliestTaskOrdinal()`
  - `testInterruptID_DerivedFromTaskID()`
  - `testResume_FirstCommitClearsInterruption()`
  - `testResume_CancelBeforeFirstCommit_KeepsInterruption()`
  - `testResume_VisibleOnlyFirstStep()`
  - `testApplyExternalWrites_IncrementsStepIndex_KeepsFrontier()`
  - `testApplyExternalWrites_RejectsTaskLocalWrites()`

## Deliverables

- Interrupt/resume types under `libs/hive/Sources/HiveCore/Runtime/`:
  - `HiveInterruptID.swift`
  - `HiveInterrupt.swift` / `HiveResume.swift` / `HiveInterruption.swift`
- Runtime support for:
  - selecting winning interrupt in commit
  - emitting terminal interruption outcome/event
  - resume attempt context and interruption clearing rules
  - external writes API and validation
- Tests for all the required cases above.

## Work breakdown

1. Implement interrupt types and ID derivation (`HINT1` + taskID rawValue → SHA-256 hex).
2. Add interrupt selection during commit after a step would otherwise commit.
3. Enforce the commit-time rule from §12.2:
   - if an interrupt is selected at a boundary and no `checkpointStore` is configured, the boundary fails with `HiveRuntimeError.checkpointStoreMissing` and MUST NOT commit.
4. Implement resume attempt semantics:
   - checkpoint load/decode/version validation is Plan 09; Plan 08 owns resume *visibility* and *clearing* rules once a valid “paused boundary” is present in thread state
   - `HiveRunContext.resume` visible only in first resumed step
   - clearing rules based on whether a step successfully commits
5. Implement `applyExternalWrites`:
   - baseline rules per §10.0:
     - if thread has a pending interruption, fail before committing with `HiveRuntimeError.interruptPending`
     - if baseline was loaded from checkpoint, validate `schemaVersion`/`graphVersion` before committing
     - join barriers are not consumed or updated (no nodes executed)
   - write validation per §10.0 (fail with no commit on any violation):
     - unknown channel → `unknownChannelID`
     - taskLocal write → `taskLocalWriteNotAllowed`
     - type mismatch: debug `preconditionFailure`, release `channelTypeMismatch`
     - updatePolicy violations and reducer throws abort the synthetic step
   - commits a synthetic boundary (stepIndex + 1) while keeping the persisted frontier unchanged
   - if `checkpointStore` is configured, MUST save a checkpoint for this synthetic boundary regardless of `checkpointPolicy` (abort commit on save error)
   - emits deterministic events exactly as required for a committed step with `frontierCount = 0` (Plan 06 provides event plumbing)
6. Add tests.

## Acceptance criteria

- All required interrupt/resume/external write tests pass deterministically.
