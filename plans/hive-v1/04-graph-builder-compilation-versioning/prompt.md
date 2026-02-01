# Codex prompt — Plan 04 (Graph builder + versioning)

You are implementing **Plan 04** from `plans/hive-v1/04-graph-builder-compilation-versioning/plan.md`.

## Objective

Build the graph builder/compile pipeline and version hashing (HSV1/HGV1) per `HIVE_SPEC.md` §9 and §14.3, with golden tests.

## Read first

- `HIVE_SPEC.md` §9.0–§9.3
- `HIVE_SPEC.md` §14.3
- `HIVE_SPEC.md` §17.1–§17.2 (goldens + required tests)

## Required tests (minimum)

- `testSchemaVersion_GoldenHSV1()`
- `testGraphVersion_GoldenHGV1()`
- `testCompile_DuplicateChannelID_Fails()`
- `testCompile_TaskLocalUntracked_Fails()`
- `testCompile_NodeIDReservedJoinCharacters_Fails()`

## Constraints

- Deterministic validation order and tie-break rules are part of the API contract.
- Join barrier IDs are canonical and drive checkpoint keys; implement exactly.

## Commands

- `cd libs/hive && swift test`

