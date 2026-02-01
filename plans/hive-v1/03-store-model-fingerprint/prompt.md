# Codex prompt — Plan 03 (Store + fingerprint)

You are implementing **Plan 03** from `plans/hive-v1/03-store-model-fingerprint/plan.md`.

## Objective

Implement the store model (`HiveGlobalStore`, `HiveTaskLocalStore`, `HiveStoreView`) plus deterministic `initialCache` and task-local fingerprinting per `HIVE_SPEC.md` §7.

## Spec anchors

- `HIVE_SPEC.md` §7.1–§7.3
- `HIVE_SPEC.md` §17.1–§17.2 (goldens + required tests)

## Required tests (minimum)

- `testInitialCache_EvaluatedOnceInLexOrder()`
- `testTaskLocalFingerprint_EmptyGolden()`
- `testTaskLocalFingerprintEncodeFailure_Deterministic()`

## Constraints

- Determinism is non-negotiable: initialCache ordering, fingerprint canonical bytes, and error selection must be stable.
- Stores must enforce `unknownChannelID` and `scopeMismatch` exactly as spec’d.

## Commands

- `cd libs/hive && swift test`
