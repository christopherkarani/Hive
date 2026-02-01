# Codex prompt — Plan 01 (Schema/channels/codecs/writes)

You are implementing **Plan 01** from `plans/hive-v1/01-schema-channels-codecs-writes/plan.md`.

## Objective

Implement the `HiveCore` schema/channel foundation: IDs/keys/specs, codecs, type-erased specs, and write representations, with Swift Testing coverage.

## Read first (spec anchors)

- `HIVE_SPEC.md` §6 (all)
- `HIVE_SPEC.md` §10.1 (`HiveInputContext`)
- `HIVE_SPEC.md` §14.4 (codec requirements; you may only need the modeling now)

## Constraints

- Keep APIs hard to misuse: typed keys for reads/writes; scope/persistence/updatePolicy is explicit.
- No runtime engine in this plan. Don’t implement supersteps/commit logic yet.
- Include the core `HiveReducer<Value>` type (standard reducer factories are Plan 02).

## Files to create (suggested by `HIVE_V1_PLAN.md` layout)

- `libs/hive/Sources/HiveCore/Schema/HiveSchema.swift`
- `libs/hive/Sources/HiveCore/Schema/HiveChannelID.swift`
- `libs/hive/Sources/HiveCore/Schema/HiveChannelKey.swift`
- `libs/hive/Sources/HiveCore/Schema/HiveChannelSpec.swift`
- `libs/hive/Sources/HiveCore/Schema/HiveCodec.swift`
- `libs/hive/Sources/HiveCore/Schema/AnyHiveChannelSpec.swift`
- `libs/hive/Sources/HiveCore/Schema/AnyHiveWrite.swift`

## Tests to add

Add small Swift Testing tests under `libs/hive/Tests/HiveCoreTests/Schema/` verifying:
- `AnyHiveChannelSpec` metadata preservation
- codec round-trip for a simple value
- `AnyHiveWrite` creation produces the correct `HiveChannelID` and preserves the value as `any Sendable`

## Commands

- `cd libs/hive && swift test`
