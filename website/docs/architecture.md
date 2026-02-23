---
sidebar_position: 2
title: Architecture
description: Module layout, dependency graph, and BSP execution flow in Hive.
---

# Architecture

## Module Layout

```
HiveCore  (zero external dependencies — pure Swift)
├── HiveDSL             Result-builder workflow DSL
├── HiveConduit          Conduit model client adapter
├── HiveCheckpointWax    Wax-backed checkpoint store
└── HiveRAGWax           Wax-backed RAG snippets

Hive  (umbrella — re-exports Core + DSL + Conduit + CheckpointWax)
HiveMacros              @HiveSchema / @Channel / @WorkflowBlueprint
```

## Module Dependency Graph

| Module | Dependencies | Purpose |
|--------|-------------|---------|
| `HiveCore` | None | Schema, graph, runtime, store — zero external deps |
| `HiveDSL` | HiveCore | Result-builder workflow DSL |
| `HiveConduit` | HiveCore, Conduit | LLM provider adapter |
| `HiveCheckpointWax` | HiveCore, Wax | Persistent checkpoints |
| `HiveRAGWax` | HiveCore, Wax | Vector RAG persistence |
| `HiveSwiftAgents` | HiveCore | SwiftAgents compatibility |
| `Hive` | All above | Umbrella re-export |

Depend on `HiveCore` alone for zero external dependencies, or `Hive` for batteries-included.

## HiveCore Internal Layout

| Directory | Responsibility |
|-----------|---------------|
| `Schema/` | Channel specs, keys, reducers, codecs, schema registry, type erasure |
| `Store/` | Global store, task-local store, store view, initial cache, fingerprinting |
| `Graph/` | Graph builder, graph description, Mermaid export, ordering, versioning |
| `Runtime/` | Superstep execution, frontier computation, event streaming, interrupts, retry |
| `Checkpointing/` | Checkpoint format and store protocol |
| `HybridInference/` | Model tool loop (ReAct), inference types |
| `Memory/` | Memory store protocol, in-memory implementation |
| `DataStructures/` | Bitset, inverted index |
| `Errors/` | Runtime errors, error descriptions |

## Key Execution Flow

```
Schema defines channels → Graph compiled from DSL/builder → Runtime executes supersteps:
  1. Frontier nodes execute concurrently (lexicographic order for determinism)
  2. Writes collected, reduced, committed atomically
  3. Routers run on fresh post-commit state
  4. Next frontier scheduled
  5. Repeat until End() or Interrupt()
```

## Status

| Component | Status |
|-----------|--------|
| HiveCore (schema, graph, runtime, store) | **Stable** |
| HiveDSL (workflow result builder) | **Stable** |
| HiveConduit (LLM adapter) | **Stable** |
| HiveCheckpointWax (persistence) | **Stable** |
| HiveRAGWax (vector recall) | **Stable** |
| HiveMacros (@HiveSchema) | **Preview** |
| Distributed execution | Planned |
| Visual graph editor | Planned |
| SwiftUI bindings | Planned |
