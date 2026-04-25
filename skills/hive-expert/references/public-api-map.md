# Public API Map

## Imports
- One-stop: `import Hive` re-exports `HiveCore`.
- Minimal core: `import HiveCore`.

## Products and Targets
- `Hive`: umbrella library that only re-exports `HiveCore`.
- `HiveCore`: deterministic graph runtime.
- `HiveTinyGraphExample`: executable example using `HiveGraphBuilder`.

## HiveCore
- Schema + channels:
  - `HiveSchema`
  - `HiveChannelID`, `HiveChannelKey`, `HiveChannelSpec`, `AnyHiveChannelSpec`
  - `HiveReducer` and standard reducers
  - `HiveCodec`, `HiveAnyCodec`, `HiveJSONCodec`
- Graph compilation:
  - `HiveGraphBuilder`
  - `HiveNodeID`, `Route`, `HiveRouter`
  - `HiveJoinEdge`, `HiveOutputProjection`, `CompiledHiveGraph`
- Runtime execution:
  - `HiveRuntime`
  - `HiveRunOptions`, `HiveCheckpointPolicy`
  - `HiveRunHandle`, `HiveRunOutcome`, `HiveRunOutput`
  - `HiveEvent`, `HiveEventKind`, `HiveEventID`
- Interrupt/resume:
  - `HiveInterruptRequest`, `HiveInterrupt`, `HiveResume`, `HiveInterruption`, `HiveInterruptID`
- Checkpoints and replay:
  - `HiveCheckpointStore`, `AnyHiveCheckpointStore`, `InMemoryHiveCheckpointStore`
  - checkpoint records, metadata, selectors, and replay compatibility helpers
- Environment:
  - `HiveEnvironment`, `HiveClock`, `HiveLogger`

## Removed Surfaces
This package no longer exposes DSL, agent, chat/model/tool, memory/RAG, Conduit, Wax adapter, or macro APIs.
