# API Surface Catalog
Generated: 2026-04-25 | Framework: Hive | Branch: codex/hive-core-runtime-cleanup

## Executive Summary

| Metric | Count |
|--------|-------|
| Products | 3 |
| Targets | 5 |
| Public type declarations | 113 |
| Public member declarations | 361 |
| Protocols | 7 |
| Actors | 1 |

## Products

| Product | Purpose |
|---------|---------|
| `Hive` | Umbrella module that re-exports `HiveCore`. |
| `HiveCore` | Deterministic Swift graph runtime. |
| `HiveTinyGraphExample` | Executable example built with `HiveGraphBuilder`. |

## Targets

| Target | Purpose |
|--------|---------|
| `Hive` | Thin public umbrella target. |
| `HiveCore` | Schema, graph, runtime, events, checkpoints, replay, cache, retry, and store APIs. |
| `HiveTinyGraphExample` | Tiny graph runtime example. |
| `HiveCoreTests` | Core runtime tests. |
| `HiveTests` | Umbrella import tests. |

## Entry Points

| Type | Kind | File | Notes |
|------|------|------|-------|
| `HiveRuntime` | actor | `Runtime/HiveRuntime.swift` | Executes compiled graphs and exposes run, resume, state, fork, checkpoint, and external-write operations. |
| `HiveGraphBuilder` | struct | `Graph/HiveGraphBuilder.swift` | Imperative graph construction with nodes, static edges, routers, joins, and graph compilation. |
| `HiveSchema` | protocol | `Schema/HiveSchema.swift` | Defines input mapping and the typed channel registry for a graph. |
| `HiveEnvironment` | struct | `Runtime/HiveEnvironment.swift` | Runtime dependencies: context, clock, logger, and checkpoint store. |
| `HiveRunOptions` | struct | `Runtime/HiveRunOptions.swift` | Run configuration for step limits, checkpoints, event buffering, streaming mode, retry policy, cache policy, and output projection. |

## Protocols

| Protocol | File | Purpose |
|----------|------|---------|
| `HiveSchema` | `Schema/HiveSchema.swift` | Schema contract for typed graph state. |
| `HiveCodec` | `Schema/HiveCodec.swift` | Serialization contract for checkpointed values. |
| `HiveCheckpointStore` | `Checkpointing/HiveCheckpointTypes.swift` | Minimal checkpoint persistence contract. |
| `HiveCheckpointQueryableStore` | `Checkpointing/HiveCheckpointTypes.swift` | Optional checkpoint listing and point-load capability. |
| `HiveClock` | `Runtime/HiveEnvironment.swift` | Testable time source and sleeper. |
| `HiveLogger` | `Runtime/HiveEnvironment.swift` | Runtime logging hook. |
| `HiveCacheKeyProviding` | `Runtime/HiveCachePolicy.swift` | Node cache key customization. |

## Core Data Types

| Type | File | Purpose |
|------|------|---------|
| `HiveNodeID` | `Graph/HiveRouting.swift` | Stable node identifier. |
| `Route` | `Graph/HiveRouting.swift` | Routing decision: graph edges, explicit destinations, or end. |
| `HiveRouter` | `Graph/HiveRouting.swift` | Synchronous deterministic routing closure. |
| `HiveChannelID` | `Schema/HiveChannelID.swift` | Stable channel identifier. |
| `HiveChannelKey` | `Schema/HiveChannelKey.swift` | Typed channel key. |
| `HiveChannelSpec` | `Schema/HiveChannelSpec.swift` | Channel scope, reducer, persistence, and codec configuration. |
| `AnyHiveChannelSpec` | `Schema/AnyHiveChannelSpec.swift` | Type-erased channel spec for heterogeneous schema arrays. |
| `AnyHiveWrite` | `Schema/AnyHiveWrite.swift` | Type-erased channel write emitted by nodes. |
| `HiveReducer` | `Schema/HiveReducer.swift` | Deterministic write merge strategy. |
| `HiveJSONCodec` | `Schema/HiveJSONCodec.swift` | JSON codec for `Codable` values. |
| `HiveAnyCodec` | `Schema/HiveCodec.swift` | Type-erased codec. |
| `HiveGlobalStore` | `Store/HiveGlobalStore.swift` | Global channel storage. |
| `HiveTaskLocalStore` | `Store/HiveTaskLocalStore.swift` | Per-task overlay storage. |
| `HiveStoreView` | `Store/HiveStoreView.swift` | Read-only merged view used by nodes and routers. |

## Graph Types

| Type | File | Purpose |
|------|------|---------|
| `HiveNodeOptions` | `Graph/HiveGraphBuilder.swift` | Node configuration flags. |
| `HiveNodeRunWhen` | `Graph/HiveNodeRunWhen.swift` | Channel-version trigger rules. |
| `HiveCompiledNode` | `Graph/HiveGraphBuilder.swift` | Compiled node metadata and action. |
| `HiveJoinEdge` | `Graph/HiveGraphBuilder.swift` | Barrier edge from multiple parents to a target. |
| `CompiledHiveGraph` | `Graph/HiveGraphBuilder.swift` | Immutable graph ready for runtime execution. |
| `HiveGraphDescription` | `Graph/HiveGraphDescription.swift` | Stable graph description for diagnostics and hashing. |
| `HiveGraphMermaidExporter` | `Graph/HiveGraphMermaidExporter.swift` | Mermaid graph exporter. |
| `HiveOutputProjection` | `Graph/HiveOutputProjection.swift` | Final output selection. |

## Runtime Types

| Type | File | Purpose |
|------|------|---------|
| `NodeAction` | `Runtime/HiveTaskTypes.swift` | Node execution closure type. |
| `HiveNodeInput` | `Runtime/HiveTaskTypes.swift` | Inputs passed to node execution. |
| `HiveNodeOutput` | `Runtime/HiveTaskTypes.swift` | Node result containing writes, spawn seeds, route, and interrupt. |
| `HiveTaskSeed` | `Runtime/HiveTaskTypes.swift` | Seed for spawned work. |
| `HiveTask` | `Runtime/HiveTaskTypes.swift` | Runtime task metadata. |
| `HiveRunContext` | `Runtime/HiveTaskTypes.swift` | Run-scoped context visible inside node actions. |
| `HiveRunHandle` | `Runtime/HiveRunTypes.swift` | Events stream and terminal outcome task for a run attempt. |
| `HiveRunOutcome` | `Runtime/HiveRunTypes.swift` | Finished, interrupted, cancelled, or out-of-steps result. |
| `HiveRunOutput` | `Runtime/HiveRunTypes.swift` | Full-store or projected-channel output. |
| `HiveRetryPolicy` | `Runtime/HiveRetryPolicy.swift` | Deterministic retry configuration. |
| `HiveCachePolicy` | `Runtime/HiveCachePolicy.swift` | Node cache configuration. |

## Checkpoint and Resume Types

| Type | File | Purpose |
|------|------|---------|
| `HiveCheckpointPolicy` | `Runtime/HiveRunOptions.swift` | Disabled, every-step, periodic, or interrupt checkpoint policy. |
| `HiveCheckpoint` | `Checkpointing/HiveCheckpointTypes.swift` | Full persisted runtime snapshot. |
| `HiveCheckpointID` | `Checkpointing/HiveCheckpointTypes.swift` | Stable checkpoint identifier. |
| `HiveCheckpointSummary` | `Checkpointing/HiveCheckpointTypes.swift` | Query result metadata. |
| `HiveCheckpointTask` | `Checkpointing/HiveCheckpointTypes.swift` | Persisted frontier task state. |
| `AnyHiveCheckpointStore` | `Checkpointing/HiveCheckpointTypes.swift` | Type-erased checkpoint store. |
| `HiveInterruptRequest` | `Runtime/HiveInterrupts.swift` | Node request to pause a run. |
| `HiveInterrupt` | `Runtime/HiveInterrupts.swift` | Persisted interrupt payload. |
| `HiveResume` | `Runtime/HiveInterrupts.swift` | Resume payload delivered to resumed tasks. |
| `HiveInterruption` | `Runtime/HiveInterrupts.swift` | Terminal interrupted outcome payload. |

## Events and Replay

| Type | File | Purpose |
|------|------|---------|
| `HiveEvent` | `Runtime/HiveEvents.swift` | Runtime event. |
| `HiveEventKind` | `Runtime/HiveEvents.swift` | Lifecycle, store, checkpoint, interrupt, and debug event cases. |
| `HiveEventID` | `Runtime/HiveEvents.swift` | Stable event identifier. |
| `HiveEventStreamViews` | `Runtime/HiveEventStreamViews.swift` | Typed event stream projections. |
| `HiveEventTranscript` | `Runtime/HiveTranscript.swift` | Canonical transcript for replay and hashing. |
| `HiveTranscriptHasher` | `Runtime/HiveTranscript.swift` | Deterministic transcript and final-state hashes. |
| `HiveRuntimeStateSnapshot` | `Runtime/HiveRuntimeStateSnapshot.swift` | Runtime state snapshot for inspection. |

## Error Types

| Type | File | Purpose |
|------|------|---------|
| `HiveCompilationError` | `Schema/HiveCompilationError.swift` | Graph and schema compilation errors. |
| `HiveRuntimeError` | `Errors/HiveRuntimeError.swift` | Runtime execution errors. |
| `HiveRunOptionsValidationError` | `Errors/HiveRunOptionsValidationError.swift` | Fail-fast run option validation errors. |
| `HiveCheckpointQueryError` | `Errors/HiveCheckpointQueryError.swift` | Unsupported checkpoint query operations. |
| `HiveExternalWriteError` | `Errors/HiveExternalWriteError.swift` | External write validation failures. |
| `HiveEventReplayCompatibilityError` | `Errors/HiveEventReplayCompatibilityError.swift` | Replay schema compatibility failures. |

## Intentional Removals

The current package is intentionally limited to the deterministic graph runtime. Non-core composition layers, provider adapters, long-term memory helpers, and agent-oriented chat/tool abstractions are not part of this package surface.
