# Plan 04 — Graph builder, compilation validation, join IDs, version hashing

## Goal

Implement graph construction + compilation in `HiveCore`:

- `HiveGraphBuilder<Schema>` → `CompiledHiveGraph<Schema>`
- compilation validation with deterministic failure precedence
- join edge modeling and canonical join barrier IDs
- output projection normalization + validation
- canonical `schemaVersion` and `graphVersion` hashing (golden fixtures)

## Spec anchors

- `HIVE_SPEC.md` §9.0–§9.3 (builder, compilation errors, join semantics, output projection)
- `HIVE_SPEC.md` §14.3 (versioning canonical bytes for HSV1/HGV1)
- `HIVE_SPEC.md` §17.1 (golden digests) + §17.2 related tests

## Deliverables

- `libs/hive/Sources/HiveCore/Graph/`:
  - `HiveNodeID.swift`
  - `HiveNext.swift`
  - `HiveRouter.swift`
  - `HiveRetryPolicy.swift` (structure only; runtime validation is Plan 07)
  - `HiveJoinEdge.swift`
  - `HiveOutputProjection.swift`
  - `HiveCompiledNode.swift`
  - `HiveGraphBuilder.swift`
  - `CompiledHiveGraph.swift`
- `libs/hive/Sources/HiveCore/Versioning/`:
  - `HiveSchemaVersion.swift`
  - `HiveGraphVersion.swift`
- Swift Testing coverage for the spec’s compilation and versioning requirements, at least:
  - `testSchemaVersion_GoldenHSV1()`
  - `testGraphVersion_GoldenHGV1()`
  - `testCompile_DuplicateChannelID_Fails()`
  - `testCompile_TaskLocalUntracked_Fails()`
  - `testCompile_NodeIDReservedJoinCharacters_Fails()`

## Work breakdown

1. Implement identifiers and routing types (§9.1), plus ordering-by-UTF8 rule.
   - Include `HiveNext` normalization: treat `HiveNext.nodes([])` as `.end`.
2. Implement output projection normalization (§9.2).
   - Normalize by de-duping by `HiveChannelID.rawValue`, then sorting ascending by UTF-8 bytes.
   - Add at least one focused test for the compile-time projection failures (`outputProjectionUnknownChannel`, `outputProjectionIncludesTaskLocal`), even though they’re not listed in the §17.2 matrix.
3. Implement `HiveGraphBuilder` capture:
   - nodes, routers, static edges (insertion order), join edges (insertion order), output projection
4. Implement compilation:
   - validations in the exact order required by §9.0
   - deterministic tie-breakers for “multiple violations”
5. Implement join edge canonical IDs exactly as specified (§9.1/§9.3).
6. Implement canonical hashing:
   - HSV1 from schema channel specs sorted by channelID
   - HGV1 from compiled graph (structure only; routers only contribute “from” node IDs)
     - includes all nodes in `nodesByID` (including unreachable)
     - uses exact UTF-8 byte counts and raw UTF-8 bytes (no Unicode normalization)
   - SHA-256 lowercase hex of canonical bytes
7. Add tests using the golden fixtures from §17.1.

## Acceptance criteria

- Golden digests match exactly.
- Compilation errors match the spec enum cases and deterministic selection rules.
