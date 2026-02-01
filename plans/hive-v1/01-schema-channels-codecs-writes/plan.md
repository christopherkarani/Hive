# Plan 01 — Schema, channels, codecs, type-erased specs, writes

## Goal

Implement the **schema/channel model** foundations in `HiveCore`, including:

- `HiveSchema`, channel IDs/keys, channel specs (scope/persistence/updatePolicy), initial values
- Codecs (encode/decode canonical bytes)
- Type erasure for channel specs (`AnyHiveChannelSpec`) and checkpoint store (`AnyHiveCheckpointStore` later)
- Typed/erased write model (`AnyHiveWrite`)
- Schema registry/type registry construction rules (used by compilation + runtime)

This plan intentionally avoids the runtime step engine; it builds the “static” model and validation primitives the rest of Hive uses.

## Spec anchors (normative)

- `HIVE_SPEC.md` §6 (Schema and channel model), including:
  - §6.4 Codecs
  - §6.5 AnyHiveChannelSpec (type erasure)
  - §6.6 Writes
- `HIVE_SPEC.md` §10.1 (`HiveInputContext`) and §6.1 (`HiveSchema.inputWrites`)
- `HIVE_SPEC.md` §11.0 (error cases related to codecs/type mismatch/unknown channels)
- `HIVE_SPEC.md` §14.4 (codec requirements + missing codec failure selection)

## Deliverables

- New `HiveCore` types under `libs/hive/Sources/HiveCore/Schema/`:
  - `HiveSchema.swift`
  - `HiveInputContext.swift`
  - `HiveChannelID.swift`
  - `HiveChannelKey.swift`
  - `HiveChannelScope.swift`
  - `HiveChannelPersistence.swift`
  - `HiveUpdatePolicy.swift`
  - `HiveReducer.swift` (the core reducer type only; standard reducers are Plan 02)
  - `HiveChannelSpec.swift`
  - `HiveCodec.swift` (`HiveCodec` + `HiveAnyCodec`)
  - `AnyHiveChannelSpec.swift`
  - `AnyHiveWrite.swift`
  - `HiveWriteEmissionIndex` typealias (can live next to `AnyHiveWrite`, per §6.6)
- A schema registry that:
  - preserves the original `Schema.channelSpecs` order for builder UX, but
  - can deterministically iterate by sorted `HiveChannelID.rawValue` when required.
- Runtime type-registry modeling support (used later by store/runtime):
  - registry keyed by `HiveChannelID`
  - `HiveChannelKey<Schema, Value>` reads must enforce type safety per §6.2:
    - debug: `preconditionFailure(...)` on mismatch
    - release: throw `HiveRuntimeError.channelTypeMismatch(...)`
- Unit tests in `libs/hive/Tests/HiveCoreTests/` covering:
  - Codec round-trips and “canonical bytes” expectations for at least one simple type.
  - `AnyHiveChannelSpec` preserves required metadata (id/scope/persistence/updatePolicy/valueTypeID/codecID).
  - Writes are representable for both `.global` and `.taskLocal` channels.

## Work breakdown

1. Define the core identifiers and enums exactly as spec’d (§6.1–§6.3, §6.6).
2. Implement `HiveInputContext` and wire `HiveSchema.inputWrites(_:inputContext:)` into the public schema surface (runtime integration is Plan 05).
3. Implement `HiveCodec`:
   - `encode(_:) -> Data` and `decode(_:) -> Value`
   - a stable `id` (string) used in version hashing.
   - `HiveAnyCodec` wrapper as spec’d.
4. Implement `HiveReducer<Value>` as spec’d (standard reducers are Plan 02).
5. Implement `HiveChannelSpec`:
   - matches the spec shape: `key`, `scope`, `reducer`, `updatePolicy`, `initial`, `codec`, `persistence`.
6. Implement `AnyHiveChannelSpec`:
   - type erases `Value` while retaining metadata and `initial()` evaluation hook.
   - includes boxed reducer + optional encode/decode closures as per §6.5.
7. Implement typed + erased writes:
   - `AnyHiveWrite` as per §6.6 (`channelID` + `value`).
8. Add focused tests for the above.

## Acceptance criteria

- `swift test` passes for `HiveCoreTests`.
- Public API matches the signatures in `HIVE_SPEC.md` §6 where explicitly provided.
