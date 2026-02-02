# Plan 00 — Scaffold `libs/hive` SwiftPM workspace

## Goal

Create a SwiftPM workspace under `libs/hive` that can compile and run `swift test`, with the targets required by `HIVE_V1_PLAN.md` and referenced by `HIVE_SPEC.md`:

- `HiveCore` (runtime + public API surface)
- `HiveCheckpointWax` (Wax-backed checkpoint store)
- `HiveConduit` (Conduit model client adapter)
- SwiftAgents-on-Hive lives in the SwiftAgents repo (not a Hive target)

## Spec anchors

- `HIVE_SPEC.md` §2 (locked decisions), especially Swift 6.2 + dependency boundaries.
- `HIVE_V1_PLAN.md` §4 (Targets + suggested file structure).
  - Constraint: `HiveCore` must not import Wax/Conduit/SwiftAgents directly.

## Deliverables

- `libs/hive/Package.swift` with Hive targets and matching test targets.
- `libs/hive/Makefile` implementing `make format`, `make lint`, `make test` so the repo root `Makefile` can invoke it.
- Minimal placeholder modules so `swift test` is green even before feature work:
  - `HiveCore` exports at least a single public symbol (e.g. `public enum HiveCoreVersion { ... }`) to validate module wiring.
  - Other targets can be empty modules for now, but must compile.
- A smoke test per target to prove test discovery and linking works (Swift Testing framework).

## Work breakdown

1. Create `libs/hive` structure (`Sources/`, `Tests/`).
2. Author `Package.swift`:
   - Set tools version compatible with Swift 6.2.
   - Define products + targets.
   - Add dependencies placeholders for `Wax`, `Conduit` (exact versions can be decided during implementation; keep the structure correct).
3. Add `Makefile`:
   - `make test`: `swift test`
   - `make lint` / `make format`: either invoke installed tooling (if present) or print actionable instructions and exit 0 (don’t block contributors by default).
4. Add a minimal Swift Testing smoke test per target.

## Acceptance criteria

- `cd libs/hive && swift test` succeeds.
- `cd libs/hive && make test` succeeds.
- Root `make test` continues to work (it will now include `libs/hive/Makefile`).
