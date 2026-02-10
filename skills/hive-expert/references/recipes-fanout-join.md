# Recipe: Fan-Out + Join (Map/Reduce)

## Goal
Run N workers in parallel (fan-out), then run a join/aggregate node only after all workers have completed for the current barrier cycle.

## Use HiveCore (Builder) When
- You need maximum control over task-local payload layout and scheduling.

### Sketch (Builder)
1. Define a schema:
   - global aggregation channel: e.g. `results: [Result]` with reducer `.append()` and `updatePolicy: .multi`
   - task-local payload channel for each worker (checkpointed): e.g. `workItem: WorkItem`
1. In a “fan-out” node:
   - emit `spawn: [HiveTaskSeed(nodeID: workerNode, local: overlayWithWorkItem)]`
   - optionally `next: .useGraphEdges` if the fan-out node also participates in the join barrier
1. In each worker node:
   - read task-local payload, emit a write to the global aggregation channel
1. Add a join edge:
   - parents: the set of worker node IDs (and any other parent nodes that must participate)
   - target: the aggregator node ID

## Use HiveDSL When
- You want composable components and effects.

### Sketch (DSL)
1. Use `Node("FanOut") { input in ... }` to compute work and `SpawnEach(...)` (or explicit spawn seeds) to schedule workers.
1. Use `Join(parents: [...], to: "Aggregate")` to gate aggregation.
1. Reducer choice is the design lever:
   - append for logs/results
   - setUnion for dedup
   - dictionaryMerge for keyed aggregations

## Common Failure Modes
- Join never fires:
  - One of the parents is never scheduled/executed for this barrier cycle.
  - Parent IDs mismatch (wrong node IDs in join edge).
- Aggregation is non-deterministic:
  - Reducer depends on unordered iteration (e.g., plain dictionary iteration).
  - Writes include timestamps/random values.

