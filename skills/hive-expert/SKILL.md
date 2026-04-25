---
name: hive-expert
description: "Become an expert in Hive, a deterministic Swift graph runtime. Use when designing, implementing, testing, or debugging HiveCore graphs: schemas, channels, reducers, HiveRuntime supersteps/events, joins/fan-out, interrupts/resume, checkpointing, replay, and deterministic observability."
---

# Hive Expert

## Overview

Design and ship **deterministic, testable graph runtimes** in Swift 6.2 using HiveCore. Hive is intentionally focused on graph execution: schemas, channels, reducers, routing, joins, checkpoints, interrupts/resume, replay, and event traces.

## Working Style

1. Ask only for missing product behavior:
   - What state belongs in global channels versus task-local channels?
   - Does the workflow need checkpointing, interrupt/resume, or replay compatibility?
   - What events or run outputs must be stable for tests?
1. Propose a minimal typed architecture:
   - `HiveSchema` + channel specs + reducers/update policies.
   - `HiveGraphBuilder` nodes, edges, routers, joins, and spawn.
   - `HiveRuntime` wired with `HiveEnvironment(context:clock:logger:checkpointStore:)`.
1. Write Swift Testing coverage first for graph compilation, runtime behavior, checkpoints, and determinism.
1. Keep the public surface core-only. Do not add DSL, agent, model, RAG, Conduit, or Wax adapter APIs back into this package.

## Quick Start

Hive is a BSP-style runtime:
- **Channels** are typed state slots declared in a `HiveSchema`.
- **Writes** target channels; **reducers** merge multiple writes per superstep.
- Each **superstep** runs the current **frontier** of tasks, then commits writes and schedules the next frontier.
- **Static edges**, **routers**, **spawn**, and **join edges** determine what runs next.
- **Interrupt/resume**, **checkpointing**, and **replay validation** are core runtime capabilities.

Read first:
- `references/mental-model.md`
- `references/public-api-map.md`
- `references/sharp-edges.md`

## Core Invariants

- Channel IDs are globally unique per schema.
- `.taskLocal` channels must be `.checkpointed` and require a codec path.
- `.global` channels require a codec when `persistence == .checkpointed`.
- Reducers, routers, graph descriptions, event encodings, schema versions, and graph versions must be deterministic.
- Non-core user observability belongs in `customDebug` events.

## Common Recipes

### Fan-Out + Join
Use `spawn` to create worker tasks and `HiveGraphBuilder.addJoinEdge` to gate an aggregate node until all parents reach the barrier.
Read: `references/recipes-fanout-join.md`

### Human Approval Gate
Return `HiveNodeOutput(interrupt:)` to pause deterministically, then call `resume` with a `HiveResume` payload.
Read: `references/recipes-interrupt-resume.md`

### Checkpointed Runs
Provide a core `HiveCheckpointStore` through `HiveEnvironment` and enable `HiveRunOptions.checkpointPolicy`.
Read: `references/recipes-checkpointing.md`

### Deterministic Event Traces
Use `HiveRunOptions(deterministicStreamBuffering: true)` for stable stream ordering in golden tests.
Read: `references/testing-and-determinism.md`

## Troubleshooting

- Compilation fails: check start nodes, duplicate node IDs, unknown edge/router/join endpoints, and reserved join characters.
- Runtime fails before step 0: check missing codecs, schema version mismatch, graph version mismatch, and checkpoint fingerprints.
- Step aborts with no commit: check unknown channel writes, update policy violations, reducer errors, and checkpoint save errors.
- Event tests drift: check nondeterministic metadata, stream buffering options, and event buffer capacity.

## Resources

### scripts/
- `scripts/hive_api_map.py`: scan a Hive source checkout to list core public entry points.

### references/
- `references/mental-model.md`: channel/reducer/superstep/join/interrupt/checkpoint mental model.
- `references/public-api-map.md`: current import and core API surface.
- `references/sharp-edges.md`: invariants, pitfalls, and gotchas.
- `references/runtime-semantics.md`: superstep commit rules, retries/cancellation, external writes, and event behavior.
- `references/recipes-*.md`: core graph runtime patterns.
- `references/testing-and-determinism.md`: golden tests and deterministic event semantics.
- `references/troubleshooting.md`: symptom to likely cause to fix.
