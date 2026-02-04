Prompt:
Add failing Swift Testing tests for HiveCore v1.1 channel versioning + `versions_seen` triggers, per `plans/plan-14-v1.1-implementation.md`.

Goal:
Define the behavioral contract (TDD) for:
- global channel version counters (increment once per committed step per written channel)
- per-node `versionsSeen` snapshots
- trigger filtering (`runWhen: .always/.anyOf/.allOf`)
- join-edge seeds bypassing triggers (to preserve join semantics)
- checkpoint migration defaults for older checkpoints missing v1.1 fields

Task Breakdown:
1) Add a new test file under `libs/hive/Tests/HiveCoreTests/Runtime/` covering:
   - version increment semantics (writes vs no writes)
   - versionsSeen snapshot update timing (step start)
   - scheduling differences when triggers are enabled
2) Add or extend checkpoint tests under `libs/hive/Tests/HiveCoreTests/Runtime/` to cover:
   - decoding a checkpoint missing v1.1 fields yields deterministic defaults
   - resume parity for a trigger-enabled graph (checkpoint+resume matches uninterrupted)
3) Include a join-edge regression test demonstrating:
   - a join target with `runWhen` that would otherwise block must still be scheduled when the join becomes available
4) Ensure tests compile but fail until implementation exists (use `#expect` and explicit assertions).

Expected Output:
- New/updated Swift Testing tests that fail on main and pass after implementation:
  - `libs/hive/Tests/HiveCoreTests/Runtime/HiveRuntimeChannelVersioningTriggerTests.swift`
  - If needed, updates to existing checkpoint/join tests to reflect v1.1 behavior (but do not change v1 semantics assertions).

