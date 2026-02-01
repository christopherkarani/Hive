# Codex prompt — Plan 09 (Checkpointing + Wax)

You are implementing **Plan 09** from `plans/hive-v1/09-checkpointing-wax/plan.md`.

## Objective

Implement checkpointing end-to-end per `HIVE_SPEC.md` §14, including encoding/decoding/validation, version mismatch checks, and a Wax-backed store in `HiveCheckpointWax`.

## Read first

- `HIVE_SPEC.md` §14.1–§14.4
- `HIVE_SPEC.md` §11.0 (checkpoint errors + timing)
- `HIVE_SPEC.md` §17.2 tests listed in the plan

## Constraints

- Missing codec checks are before step 0 and pick the smallest `channelID`.
- Checkpoint save failure aborts the boundary (no commit) and emits no commit-scoped events.
- Implement §14.2 store semantics: `save` is atomic w.r.t `loadLatest`, “latest” is max `stepIndex` (tie-break by max `id.rawValue`), and `loadLatest` never returns partial checkpoints.

## Commands

- `cd libs/hive && swift test`
