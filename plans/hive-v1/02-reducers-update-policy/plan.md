# Plan 02 — Reducers and updatePolicy semantics

## Goal

Implement reducers and deterministic merge behavior in `HiveCore`, including:

- Standard reducers listed in the spec
- A reusable deterministic “reduce write-batch” primitive that the runtime commit phase can call later

This plan does **not** implement runtime commits; it provides the pure merging logic and tests for reducer behavior and deterministic key ordering.

## Spec anchors

- `HIVE_SPEC.md` §8 (Reducers), especially:
  - standard reducers and their exact semantics
  - updatePolicy rules (how `.single` vs `.multi` is interpreted)
  - dictionary merge key ordering (ascending lexicographic by UTF-8)

## Deliverables

- Standard reducer factories (names per spec) in `HiveReducer+Standard.swift` (or similar). (`HiveReducer` itself is Plan 01.)
- A pure helper that reduces in deterministic order:
  - input: current value + ordered updates
  - output: reduced value (or throws)
- Swift Testing coverage:
  - `dictionaryMerge` processes update keys in ascending order
  - `append` preserves element order
  - `lastWriteWins` ignores `current`

## Work breakdown

1. Implement `HiveReducer` as spec’d.
2. Implement standard reducers (keep surface area minimal; avoid protocol hierarchies).
3. Add tests that directly pin semantics and deterministic ordering.

## Acceptance criteria

- Reducer semantics match `HIVE_SPEC.md` §8.
- Tests are deterministic and do not depend on hashing/Set iteration order.
- UpdatePolicy scope nuance is documented for later runtime enforcement:
  - `.global` enforcement is across all tasks in a step
  - `.taskLocal` enforcement is per task
