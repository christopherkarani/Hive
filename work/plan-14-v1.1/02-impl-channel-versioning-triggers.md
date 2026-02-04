Prompt:
Implement HiveCore v1.1 channel versioning + deterministic triggers per `plans/plan-14-v1.1-implementation.md`, making all tests from task 01 pass.

Goal:
Add the full feature surface for:
- global-only channel version counters
- per-node `versionsSeen`
- `runWhen` trigger configuration on nodes (compile-time)
- commit-time trigger filtering with join-seed bypass
- checkpoint persistence (HCP2) with backward-compatible decoding defaults
- graph versioning (HGV2 only when triggers enabled)

Task Breakdown:
1) Public API:
   - Add `HiveNodeRunWhen` (Sendable, Equatable, Codable as needed).
   - Extend `HiveGraphBuilder.addNode` to accept `runWhen:` (default `.always`) and store it in compiled graph.
   - Add compile-time validation: trigger channels exist + are global + non-empty.
2) Graph versioning:
   - Keep existing HGV1 hashing unchanged for graphs with all nodes `.always`.
   - Introduce HGV2 hashing when any node is non-default, including trigger config deterministically.
3) Runtime state:
   - Extend internal `ThreadState` to track `channelVersionsByChannelID` and `versionsSeenByNodeID`.
   - Increment channel versions once per committed step for each written global channel.
   - Snapshot `versionsSeen` at step start for trigger-enabled nodes.
4) Scheduling:
   - Apply trigger filtering at commit boundary for seeds from static edges/routers/spawn.
   - Bypass filtering for seeds originating from join-availability transitions (join edge semantics preserved).
5) Checkpointing:
   - Extend `HiveCheckpoint` to persist HCP2 fields (format tag + maps + optional debug list).
   - Update `makeCheckpoint`/`decodeCheckpoint` to save/restore new fields.
   - Ensure older checkpoints missing the new fields decode deterministically (defaults).
6) Ensure all tests from task 01 pass.

Expected Output:
- Source updates (likely):
  - `libs/hive/Sources/HiveCore/Graph/HiveGraphBuilder.swift`
  - `libs/hive/Sources/HiveCore/Graph/HiveVersioning.swift`
  - `libs/hive/Sources/HiveCore/Runtime/HiveRuntime.swift`
  - `libs/hive/Sources/HiveCore/Checkpointing/HiveCheckpointTypes.swift`
  - New file(s) for trigger types if needed (e.g., `libs/hive/Sources/HiveCore/Runtime/HiveNodeRunWhen.swift`)

