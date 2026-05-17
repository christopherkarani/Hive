# API Improvement Report
Generated: 2026-04-25 | Framework: Hive | Branch: codex/hive-core-runtime-cleanup

## Executive Summary

The cleanup pass has already made the largest API improvement: Hive is now a focused deterministic Swift graph runtime. The public package surface is `Hive` as an umbrella re-export and `HiveCore` as the runtime module. This report now tracks follow-up improvements that apply to the cleaned core package only.

| Metric | Current |
|--------|---------|
| Public type declarations | 113 |
| Public member declarations | 361 |
| Protocols | 7 |
| Actors | 1 |
| Products | `Hive`, `HiveCore`, `HiveTinyGraphExample` |

## Completed Surface Reduction

| Area | Status |
|------|--------|
| Umbrella module | `import Hive` now re-exports only `HiveCore`. |
| Core runtime | Schema, graph builder, routing, joins, runtime, events, checkpoints, interrupts/resume, stores, cache, retry, and run options remain. |
| External adapters | Removed from this package. |
| Non-core composition layer | Removed from this package. |
| Chat/tool abstractions | Removed from `HiveCore`. |
| Long-term memory helpers | Removed from `HiveCore`. |
| Cross-platform hashing | Added internal SHA-256 compatibility wrapper over Apple CryptoKit and swift-crypto. |
| Linux validation | `HiveCore` build, `Hive` build, example run, and full package tests pass in Swift 6.2 Noble. |

## Highest-Value Follow-Up Improvements

### Finding 1: Demote Internal Plumbing That Still Leaks Publicly

**Category:** Access control tightening
**Current DX:** H=3.5, A=3.0, Combined=3.25
**Impact:** Medium
**Breaking:** Yes, for users relying on implementation details

**Candidates:**
- `HiveOrdering`
- `HiveVersioning`
- `HiveChannelTypeRegistry`
- `HiveStoreSupport`
- `HiveTaskLocalFingerprint`
- `HiveBitset`

**Rationale:**
These types are useful implementation details, but they are not natural first-class concepts for users building graphs. Demoting them would reduce autocomplete noise and make the public API easier for both humans and coding agents to navigate.

**Suggested approach:**
1. Confirm no public API signatures require these names.
2. Move required test access behind `@testable import`.
3. Demote the declarations from `public` to `internal` or `package`.
4. Keep only stable diagnostic outputs public, such as graph descriptions and transcript hashes.

### Finding 2: Consolidate Type-Erasure Naming

**Category:** Naming consistency
**Current DX:** H=3.5, A=3.0, Combined=3.25
**Impact:** Medium
**Breaking:** Yes, if names change

**Current pattern:**
- `AnyHiveChannelSpec`
- `AnyHiveWrite`
- `HiveAnyCodec`
- `AnyHiveCacheKeyProvider`
- `AnyHiveCheckpointStore`

**Rationale:**
The package now has fewer type-erasure boxes, but the naming still alternates between `AnyHive...` and `HiveAny...`. Standardizing on one convention would make search and autocomplete behavior more predictable.

**Suggested approach:**
1. Prefer the existing majority convention: `AnyHive...`.
2. Rename `HiveAnyCodec` to `AnyHiveCodec` in the next hard-break window, or leave it as-is if preserving source compatibility matters more.
3. Avoid adding new type-erasure wrappers unless heterogeneous storage requires them.

### Finding 3: Clarify Version API Shape

**Category:** Namespace simplification
**Current DX:** H=4.0, A=3.5, Combined=3.75
**Impact:** Low
**Breaking:** Optional

**Current pattern:**
- `HiveVersion`
- `HiveCoreVersion`

**Rationale:**
The compatibility alias keeps existing core callers working, but the preferred version surface should be obvious. If this package accepts hard breaks, one canonical version namespace is easier to teach.

**Suggested approach:**
1. Keep `HiveVersion` as the canonical public surface.
2. Remove `HiveCoreVersion` only in a future hard-break release if source compatibility is not needed.
3. Keep examples and docs using `HiveVersion`.

### Finding 4: Tighten Event Extension Guidance

**Category:** Observability ergonomics
**Current DX:** H=4.0, A=3.5, Combined=3.75
**Impact:** Low

**Current pattern:**
- Runtime events are explicit lifecycle/checkpoint/store/interrupt cases.
- User-defined observability goes through `customDebug`.

**Rationale:**
The event schema is intentionally smaller now. Additional docs and tests should reinforce that user-specific events belong in `customDebug` metadata instead of adding new core event cases.

**Suggested approach:**
1. Keep event enum cases limited to runtime semantics.
2. Add examples that show stable `customDebug` metadata for domain events.
3. Keep replay fixtures focused on core runtime event compatibility.

## Do Not Reintroduce

The following areas were intentionally removed from this package and should not appear in future API improvement work for this repository:
- Declarative workflow composition APIs.
- Provider-specific inference adapters.
- Chat/tool loop abstractions.
- Long-term memory and retrieval helpers.
- External checkpoint persistence adapters.

If any of those capabilities are needed again, they should be evaluated as separate packages built on top of `HiveCore`, not as public API in this package.

## Recommended Next Steps

1. Decide whether the next API pass is allowed to make another hard break.
2. If yes, demote internal plumbing and standardize type-erasure naming.
3. If no, keep the current public surface stable and limit follow-up work to documentation and examples.
