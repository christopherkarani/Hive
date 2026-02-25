# Conceptual Overview

Understand Hive's architecture, the BSP execution model, and determinism guarantees.

## Overview

Hive executes agent workflows as deterministic superstep graphs. This article explains the core concepts that make Hive unique: the Bulk Synchronous Parallel (BSP) model, the module architecture, and the guarantees that enable golden testing and checkpoint resumability.

## Architecture

Hive is organized as a layered set of modules:

```
HiveCore  (zero external deps — pure Swift)
├── HiveDSL             result-builder workflow DSL
├── HiveConduit          Conduit model client adapter
├── HiveCheckpointWax    Wax-backed checkpoint store
└── HiveRAGWax           Wax-backed RAG snippets

Hive  (umbrella — re-exports Core + DSL + adapters)
```

| Module | Dependencies | Purpose |
|--------|-------------|---------|
| `HiveCore` | None | Schema, graph, runtime, store — zero external deps |
| `HiveDSL` | HiveCore | Result-builder workflow DSL |
| `HiveConduit` | HiveCore, Conduit | LLM provider adapter |
| `HiveCheckpointWax` | HiveCore, Wax | Persistent checkpoints |
| `HiveRAGWax` | HiveCore, Wax | Vector RAG persistence |
| `Hive` | All above | Umbrella re-export |

## The BSP execution model

Hive uses the Bulk Synchronous Parallel (BSP) model. Execution proceeds in discrete **supersteps**, each with three phases:

### Phase 1: Concurrent node execution

All frontier nodes execute concurrently within a `TaskGroup`. Each node reads from a pre-step snapshot — no node sees another's writes from the same step.

### Phase 2: Atomic commit

Writes are collected, ordered by `(taskOrdinal, emissionIndex)`, and reduced through each channel's reducer. Ephemeral channels reset to initial values after all reductions.

### Phase 3: Frontier scheduling

Routers run on post-commit state. Join barriers update. The next frontier is assembled, deduplicated, and optionally filtered by trigger conditions.

```
Schema defines channels
    → Graph compiled from DSL/builder
    → Runtime executes supersteps:
        1. Frontier nodes execute concurrently (lexicographic order)
        2. Writes collected, reduced, committed atomically
        3. Routers run on fresh post-commit state
        4. Next frontier scheduled
        5. Repeat until End() or Interrupt()
```

## Determinism guarantees

Hive's core invariant: **same input produces the same output and the same event trace**. This is achieved through:

1. **Lexicographic ordering** — Nodes execute in sorted order by `HiveNodeID`, ensuring consistent task ordinals.
2. **Deterministic task IDs** — SHA-256 of `(runID, stepIndex, nodeID, ordinal, fingerprint)`.
3. **Atomic superstep commits** — All writes apply together, sorted by `(taskOrdinal, emissionIndex)`.
4. **Deterministic reducers** — Associative merge strategies like `.lastWriteWins()`, `.append()`, `.setUnion()`.
5. **Sorted channel iteration** — `registry.sortedChannelSpecs` ensures consistent processing order.
6. **Deterministic token streaming** — Model tokens buffer per-task, replay in ordinal order.

These guarantees enable:

- **Golden tests** — Graph descriptions produce immutable JSON with SHA-256 version hashes. Identical graphs always produce identical JSON.
- **Reproducible debugging** — Every run of the same graph with the same input produces the exact same event sequence.
- **Checkpoint correctness** — Resuming from a checkpoint produces the same result as an uninterrupted run.

## When to use Hive

Hive is designed for workflows that benefit from determinism and structured execution:

- **Agent orchestration** — Multi-step LLM workflows with tool calling, branching, and human-in-the-loop approval.
- **Fan-out/join patterns** — Parallel processing of items with a barrier that waits for all workers to complete.
- **Resumable pipelines** — Long-running workflows that checkpoint state and resume after interruption.
- **Testable workflows** — Workflows that need golden-test-level reproducibility for CI/CD.

## Key concepts

| Concept | Description |
|---------|-------------|
| **Schema** | Declares typed channels with reducers, scopes, and codecs |
| **Channel** | A typed slot in the store (global or task-local) |
| **Reducer** | Merge strategy when multiple nodes write to the same channel |
| **Graph** | Compiled set of nodes, edges, routers, and join barriers |
| **Superstep** | One execution cycle: run frontier, commit writes, schedule next |
| **Frontier** | The set of nodes to execute in the current superstep |
| **Store** | Global + task-local state, merged into read-only views for nodes |
| **Interrupt** | Pause execution, save checkpoint, await external input |
| **Resume** | Continue from a checkpoint with a typed payload |
