# Recipe: Checkpointing + Resume

## Goal
Persist deterministic snapshots so long-running graph runs can pause, resume, fork, or replay for debugging.

## Wiring
1. Provide a core checkpoint store in `HiveEnvironment`:
   - Use `InMemoryHiveCheckpointStore` for tests and local runtime behavior.
   - Use a custom `HiveCheckpointStore` implementation outside this package for external persistence.
1. Enable a checkpoint policy via `HiveRunOptions.checkpointPolicy`:
   - `.everyStep` for maximal durability.
   - `.every(steps:)` for cheaper periodic checkpoints.
   - `.onInterrupt` for pause points only.

## Persisted State
- Global store values for `.checkpointed` global channels.
- Frontier tasks and task-local overlays.
- Join barrier state.
- Interruption payload when interrupted.

## Not Persisted
- Untracked global channels reset to initial values on checkpoint load.

## Failure Modes
- Load fails before step 0:
  - Schema version mismatch or graph version mismatch.
  - Channel fingerprint mismatch.
  - Missing or extra channel IDs relative to the checkpoint payload.
- Save fails at step boundary:
  - Codec encode errors.
  - Store errors from the checkpoint backend.
  - The step commit is aborted with no partial checkpoint.
