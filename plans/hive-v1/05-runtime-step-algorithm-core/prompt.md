# Codex prompt — Plan 05 (Runtime core algorithm)

You are implementing **Plan 05** from `plans/hive-v1/05-runtime-step-algorithm-core/plan.md`.

## Objective

Implement the deterministic superstep runtime core (`HiveRuntime` + step algorithm) per `HIVE_SPEC.md` §10.4, with Swift Testing coverage for ordering/routing/frontier/join semantics.

## Read first

- `HIVE_SPEC.md` §10.0–§10.4
- `HIVE_SPEC.md` §9.1 join semantics (consume then contribute ordering)
- `HIVE_SPEC.md` §17.2 tests listed in the plan (especially router fresh-read error abort + spawn-parent join contribution)

## Constraints

- Deterministic commit and event order must not depend on task completion timing.
- Implement the §10.0 runtime API shape (signatures) so downstream plans don’t churn:
  - `run(...)` is fully implemented for in-memory execution.
  - `resume(...)` / `applyExternalWrites(...)` may be fail-fast stubs until Plan 08 (do not “partially implement” their spec semantics here).
  - `getLatestCheckpoint(...)` may return `nil` until Plan 09 wires checkpoint I/O.
- Keep checkpoint save/load behavior out of scope here (Plan 09), but still implement §10.0 option validation + normalization:
  - validate `HiveRunOptions` fields before step 0
  - normalize `.channels(ids)` projection override to unique + lexicographically sorted

## Commands

- `cd libs/hive && swift test`
