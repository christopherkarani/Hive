# Hive Mental Model

Hive is a deterministic, superstep-based (BSP-style) runtime for agent workflows.

## Core Concepts

### Schema, Channels, Writes
- A `HiveSchema` declares **channels** (typed state slots) via `static var channelSpecs`.
- Each channel has:
  - `scope`: `.global` or `.taskLocal`
  - `reducer`: merges multiple writes in a superstep
  - `updatePolicy`: `.single` or `.multi`
  - `initial`: initial value factory
  - `persistence`: `.checkpointed` or `.untracked`
  - `codec`: required for checkpointed channels (and for all task-local)
- Nodes emit writes as `[AnyHiveWrite<Schema>]` (type-erased by channel ID).

### Stores and Views
- `HiveGlobalStore`: snapshot of **global** channel values.
- `HiveTaskLocalStore`: per-task overlay used to carry per-task payload/state across steps.
- `HiveStoreView`: read-only view composed from:
  - global snapshot
  - task-local overlay (for `.taskLocal`)
  - initial cache (fallback initial values)

### Supersteps and Frontier
In each superstep:
1. The runtime executes the current **frontier** (a set of tasks, each with a node + task-local overlay).
1. Each task produces a `HiveNodeOutput`:
   - `writes`: channel writes
   - `spawn`: `HiveTaskSeed`s to schedule next step tasks (fan-out)
   - `next`: routing decision (`HiveNext`)
   - `interrupt`: optional interrupt request
1. The runtime commits:
   - merges writes using reducers + update policy rules
   - computes next frontier using edges, routers, joins, and spawn seeds
1. Optionally checkpoint (step-synchronous).

### Edges, Routers, Joins
- Static edges (`addEdge`) are used when `next == .useGraphEdges`.
- Routers (`addRouter`) deterministically compute `HiveNext` from a store view.
- Join edges (`addJoinEdge`) implement reusable barriers:
  - a join target runs only after all parents have “fired” since the last barrier consumption
  - barrier state is persisted in checkpoints

### Interrupt / Resume
- A node may request an interrupt by setting `HiveNodeOutput.interrupt`.
- The runtime selects the interrupt deterministically (smallest task ordinal in the step).
- The run outcome becomes `.interrupted(...)` and includes a `HiveInterruptID` to resume.
- On resume, a `HiveResume` is delivered to the first resumed step via `HiveRunContext.resume`.

## Practical Reading Order
- Core types: `HiveSchema`, `HiveChannelSpec`, `HiveReducer`, `HiveGraphBuilder`, `HiveRuntime`.
- Then recipes:
  - `recipes-fanout-join.md`
  - `recipes-interrupt-resume.md`
  - `recipes-checkpointing.md`

