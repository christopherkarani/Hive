# Recipe: Checkpointing (Wax) + Resume

## Goal
Persist deterministic snapshots so long-running workflows can be paused, resumed, or replayed for debugging.

## Wiring
1. Provide a checkpoint store in the environment:
   - Use `HiveCheckpointWaxStore` (Wax-backed) and wrap it in `AnyHiveCheckpointStore`.
1. Enable a checkpoint policy via `HiveRunOptions.checkpointPolicy`:
   - `.everyStep` for maximal durability
   - `.every(steps:)` for cheaper periodic checkpoints
   - `.onInterrupt` for “pause points only”

## What’s Persisted
- Global store values for `.checkpointed` global channels.
- Frontier tasks + their task-local overlays (task-local channels must be checkpointed).
- Join barrier state.
- Interruption payload (when interrupted).

## What’s Not Persisted
- Untracked global channels: reset to initial values when loading checkpoints.

## Failure Modes
- Load fails before step 0:
  - Schema version mismatch or graph version mismatch.
  - Channel fingerprint mismatch (type/codec changes).
  - Missing/extra channel IDs relative to expected checkpoint payload.
- Save fails at step boundary:
  - Codec encode errors.
  - Store errors from underlying checkpoint backend.
  - In such cases the step commit is aborted (no partial checkpoint).

## Design Advice
- Treat codecs as part of your compatibility story:
  - Change codecs/types only with an explicit migration plan.
- Keep checkpointed values small and stable:
  - Store large blobs elsewhere; write stable IDs into channels.

