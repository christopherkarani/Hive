# Codex prompt — Plan 02 (Reducers)

You are implementing **Plan 02** from `plans/hive-v1/02-reducers-update-policy/plan.md`.

## Objective

Add standard reducers (spec §8) with focused Swift Testing coverage. (`HiveReducer` core type is implemented in Plan 01.)

## Spec anchors

- `HIVE_SPEC.md` §8

## Constraints

- Keep it pure and testable: reducers should not reference runtime types.
- Determinism: no reliance on unordered collection iteration.

## Files

- Update `HiveReducer` to add standard reducer factories, preferably in a small adjacent file (e.g. `libs/hive/Sources/HiveCore/Schema/HiveReducer+Standard.swift`).

## Tests

Add tests under `libs/hive/Tests/HiveCoreTests/Reducers/` for:
- `dictionaryMerge(valueReducer:)` deterministic ordering
- `append` stable concatenation
- `appendNonNil` nil handling

## Commands

- `cd libs/hive && swift test`
