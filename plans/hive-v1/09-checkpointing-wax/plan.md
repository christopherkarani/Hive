# Plan 09 — Checkpointing, snapshot encoding/decoding, Wax store

## Goal

Implement checkpointing end-to-end:

- checkpoint snapshot types and store contract
- checkpoint ID derivation (`HCP1` + run UUID bytes + UInt32BE(stepIndex))
- encoding/decoding rules, structural validation, deterministic failure selection
- version mismatch checks (schemaVersion/graphVersion)
- integrate a Wax-backed `HiveCheckpointStore` implementation in `HiveCheckpointWax`

## Spec anchors

- `HIVE_SPEC.md` §14.1–§14.4 (all)
- `HIVE_SPEC.md` §11.0 (checkpoint-related errors and failure timing)
- Required tests in §17.2:
  - `testCheckpoint_PersistsFrontierOrderAndProvenance()`
  - `testCheckpoint_StepIndexIsNextStep()`
  - `testCheckpointID_DerivedFromRunIDAndStepIndex()`
  - `testCheckpointDecodeFailure_FailsBeforeStep0()`
  - `testCheckpointCorrupt_JoinBarrierKeysMismatch_FailsBeforeStep0()`
  - `testCheckpointSaveFailure_AbortsCommit()`
  - `testCheckpointEncodeFailure_AbortsCommitDeterministically()`
  - `testCheckpointLoadThrows_FailsBeforeStep0()`
  - `testResume_VersionMismatchFailsBeforeStep0()`
  - `testUntrackedChannels_ResetOnCheckpointLoad()` (store rule, but enforced here)

## Deliverables

- `HiveCore` checkpointing types under `libs/hive/Sources/HiveCore/Checkpointing/`:
  - `HiveCheckpointID.swift`
  - `HiveCheckpoint.swift`
  - `HiveCheckpointStore.swift`
  - `HiveCheckpointPolicy.swift`
- Runtime integration:
  - save checkpoints at required boundaries (policy + interrupts + external writes)
  - load/decode/validate checkpoints before step 0 for resume
  - enforce `checkpointStoreMissing` before step 0 when a checkpoint store is required (resume, or `checkpointPolicy != .disabled`)
  - enforce `stepIndex` representable as `UInt32` before deriving/saving a checkpoint ID (§14.2)
  - enforce codec presence rules before step 0 (§14.4)
  - enforce version mismatch before step 0
- `HiveCheckpointWax`:
  - `WaxCheckpointStore` (or similarly named) implementing `HiveCheckpointStore`
- Swift Testing coverage for the required matrix items.

## Work breakdown

1. Implement checkpoint types and store protocol exactly as spec’d.
2. Implement canonical checkpoint ID derivation (use UUID raw bytes).
3. Implement encoding:
   - global checkpointed channels: include **every** `.global` channel with `persistence == .checkpointed`
   - task local overlay entries only (explicitly set)
   - compute/store localFingerprint (32 bytes)
   - joinBarrierSeenByJoinID contains **exactly** the compiled join IDs; each seenParents list is sorted
   - deterministic encode failure selection order
4. Implement decoding/validation before step 0:
   - missing/extra keys; fingerprint recompute; join barrier integrity checks
   - deterministic error mapping to `HiveRuntimeError` cases
5. Implement runtime integration at boundaries with strict step atomicity:
   - if save throws, boundary aborts and no state commits
6. Implement Wax store (minimal but correct, §14.2 semantics):
   - `save` atomic w.r.t `loadLatest` (never returns partially-written checkpoints)
   - “latest” = max stepIndex; tie-breaker is max checkpoint.id.rawValue lexicographically
   - after a successful save, a subsequent loadLatest returns that checkpoint or one with greater stepIndex
7. Add tests.

## Acceptance criteria

- Resume from checkpoint reproduces frontier order and taskIDs per spec.
- All checkpoint failure modes fail at the timing required (before step 0 vs during commit) and are deterministic.
