# Codex prompt — Plan 08 (Interrupt/resume/external writes)

You are implementing **Plan 08** from `plans/hive-v1/08-interrupt-resume-external-writes/plan.md`.

## Objective

Implement interrupt/resume semantics and `applyExternalWrites` per `HIVE_SPEC.md` §12 and §10.0, with the required Swift Testing coverage.

## Read first

- `HIVE_SPEC.md` §12.1–§12.3
- `HIVE_SPEC.md` §10.0 (external writes)
- `HIVE_SPEC.md` §17.2 tests listed in the plan

## Constraints

- Interrupt selection is by smallest `taskOrdinal`.
- Resume only clears pending interruption after the first committed resumed step.
- `applyExternalWrites(...)`: if `checkpointStore` is configured, it saves a checkpoint regardless of `checkpointPolicy`, and any save error aborts the boundary (no commit).
- Do not “preflight fail” runs without a checkpoint store; `checkpointStoreMissing` is enforced at commit time when an interrupt boundary is selected (per §12.2).

## Commands

- `cd libs/hive && swift test`
