# Codex prompt — Plan 12 (HiveConduit)

You are implementing **Plan 12** from `plans/hive-v1/12-conduit-adapter/plan.md`.

## Objective

Implement a Conduit-backed `HiveModelClient` in `HiveConduit`, bridging streaming tokens into Hive’s event model.

## Constraints

- `HiveCore` must remain Conduit-free; Conduit types stay in `HiveConduit`.
- Preserve the per-task stream ordering invariants in `HIVE_SPEC.md` §13.2.
- Preserve the model streaming contract in `HIVE_SPEC.md` §15.2: exactly one terminal `.final(...)` chunk on success.

## Commands

- `cd libs/hive && swift test`
