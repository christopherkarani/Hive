Prompt:
You are a senior Swift 6.2 engineer. Implement the core graph/runtime identifier and task model types for Plan 05. Do NOT edit any plan documents. Keep APIs minimal, Swifty, and well-typed.

Goal:
Define stable, deterministic identifiers and task provenance types required by the runtime core, matching HIVE_SPEC §10.3/§10.4. Ensure ordering rules are explicit and testable.

Task BreakDown
- Scan existing graph/runtime types for naming/placement conventions under `libs/hive/Sources/HiveCore/Graph/` and `libs/hive/Sources/HiveCore/Runtime/`.
- Implement identifiers:
  - `HiveThreadID`, `HiveRunID`, `HiveRunAttemptID` (if not already present), including stable ordering/comparison rules where specified.
  - `HiveTaskID` per spec (§10.3), including recomputation rules for resume compatibility.
- Implement task model types:
  - `HiveTask` (fields for node ID, input, task ordinal, etc. as needed by runtime core).
  - `HiveTaskProvenance` to represent seed vs spawn vs join-derived provenance.
- Add focused Swift Testing tests that pin ordering and task ID derivation behavior (no runtime/step engine dependencies).
- Ensure all public APIs have doc comments and visibility is minimal (internal by default).
