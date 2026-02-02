# Codex prompt — Plan 00 (Scaffold `libs/hive`)

You are implementing **Plan 00** from `plans/hive-v1/00-scaffold/plan.md`.

## Objective

Create a SwiftPM workspace under `libs/hive` with buildable targets (`HiveCore`, `HiveCheckpointWax`, `HiveConduit`) and Swift Testing smoke tests so `swift test` passes.

## Non-negotiables

- `HIVE_SPEC.md` is normative. `HIVE_V1_PLAN.md` is advisory only.
- Swift Testing framework only for tests.
- Keep the scaffold minimal: compile + test green, no premature runtime implementation.

## Required outputs

- `libs/hive/Package.swift`
- `libs/hive/Makefile` with `format`, `lint`, `test` targets
- Minimal placeholder sources for each target under:
  - `libs/hive/Sources/HiveCore/`
  - `libs/hive/Sources/HiveCheckpointWax/`
  - `libs/hive/Sources/HiveConduit/`
- Swift Testing smoke tests under `libs/hive/Tests/*Tests/`

## Commands

- Build/tests: `cd libs/hive && swift test`
- Via make: `cd libs/hive && make test`

## Definition of done

- All targets compile and tests pass.
- No extra architecture work beyond scaffolding.
