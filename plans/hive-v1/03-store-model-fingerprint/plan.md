# Plan 03 — Store model, initialCache, task-local fingerprint

## Goal

Implement the store layer in `HiveCore`:

- `HiveGlobalStore`, `HiveTaskLocalStore`, `HiveStoreView`
- deterministic `initialCache` evaluation and reuse rules
- task-local fingerprint canonical bytes + SHA-256 digest

These types are prerequisites for:
- routing fresh-read views
- task-local overlays (Send)
- checkpoint integrity validation

## Spec anchors

- `HIVE_SPEC.md` §7 (Store model) بالكامل:
  - §7.1 initialCache evaluation order and “at most once”
  - §7.2 store types + read semantics + scope safety + unknown channel errors
  - §7.3 task-local fingerprint canonical bytes + deterministic error selection
- `HIVE_SPEC.md` §17.2 tests:
  - `testInitialCache_EvaluatedOnceInLexOrder()`
  - `testTaskLocalFingerprint_EmptyGolden()`
  - `testTaskLocalFingerprintEncodeFailure_Deterministic()`

## Deliverables

- `libs/hive/Sources/HiveCore/Store/` (or `Schema/` if you keep it small) with:
  - `HiveGlobalStore.swift`
  - `HiveTaskLocalStore.swift`
  - `HiveStoreView.swift`
  - `HiveInitialCache.swift` (optional helper)
  - `HiveTaskLocalFingerprint.swift` (canonical encoding + hashing)
- Use `CryptoKit` for SHA-256.
- Swift Testing coverage for:
  - initialCache evaluated once per channel, in lexicographic channelID order
  - unknown channel and scope mismatch throw `HiveRuntimeError` as spec’d
  - empty task-local fingerprint equals the golden digest in `HIVE_SPEC.md` §17.1
  - fingerprint encode failure selects the first failing channel by lexicographic channelID scan order

## Work breakdown

1. Define a minimal “registry” representation needed to validate channel existence/scope/typeID.
2. Implement initialCache builder:
   - evaluate every spec’s `initial()` exactly once in sorted channelID order
   - store the resulting `Data`/`Any` in a way that supports typed reads without re-running `initial()`
3. Implement stores:
   - global store contains values for every `.global` channel after initialization
   - taskLocal store is overlay-only
   - store view composes global + taskLocal + initialCache fallback (for taskLocal channels)
4. Implement task-local fingerprint:
   - compute effective values (overlay or initialCache)
   - encode using codecs (required for taskLocal)
   - build `HLF1` canonical bytes with framed encoding (`HLF1` + entryCount UInt32BE + per-entry idLen/id/valueLen/value; all lengths UInt32BE) and hash with SHA-256
   - deterministic error selection by channel sort order
5. Add tests pinned to the spec fixtures.

## Acceptance criteria

- All required tests pass and match golden values exactly.
- No extra runtime semantics (commit, tasks) are implemented here.
