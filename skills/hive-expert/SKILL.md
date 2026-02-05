---
name: hive-expert
description: "Become an expert in Hive, a deterministic Swift-native graph runtime for agent workflows (Swift equivalent of LangGraph). Use when designing, implementing, testing, or debugging Hive graphs/workflows: schemas/channels/reducers, HiveRuntime supersteps/events, joins/fan-out, interrupts and resume, checkpointing (Wax), inference/tool calling (HiveModelClient/HiveToolRegistry), HiveDSL workflows/effects/model turns, and HiveMacros."
---

# Hive Expert

## Overview

Design and ship **deterministic, testable agent graphs** in Swift 6.2 using HiveCore + HiveDSL and optional adapters (Conduit/Wax). Use this skill to pick the right module surface, avoid sharp edges, and build golden-testable traces with correct superstep semantics.

## Working Style (What I Do When This Skill Triggers)

1. Ask 3 questions max:
   - Are we using `HiveGraphBuilder` (core) or `Workflow` (DSL)?
   - Do we need checkpointing/interrupt-resume/human approval?
   - Do we need model/tool integration (Conduit/SwiftAgents tools), and do we need deterministic token streaming for golden tests?
1. Propose a minimal, type-safe architecture:
   - `HiveSchema` + channel specs + reducers/update policies.
   - Graph/workflow composition (nodes/edges/joins/routers).
   - Runtime wiring: `HiveEnvironment` (clock/logger/model/tools/checkpoint store).
1. Write **Swift Testing** tests first (behavioral + determinism).
1. Implement and iterate, keeping determinism constraints explicit.

## Quick Start (Minimal Mental Model)

Hive is a BSP-style runtime:
- **Channels** are typed state slots declared in a `HiveSchema`.
- **Writes** target channels; **reducers** merge multiple writes per superstep.
- Each **superstep** runs the current **frontier** of tasks, then commits writes and schedules the next frontier.
- **Static edges** + **routers** + **spawn** + **join edges** determine what runs next.
- **Interrupt/resume** and **checkpointing** are first-class and deterministic.

To become effective quickly, read:
- `references/mental-model.md`
- `references/sharp-edges.md`

## Decision Tree (Pick the Right Surface Area)

- Want maximal control / minimum DSL?
  - Use `HiveCore`: `HiveGraphBuilder`, explicit nodes/edges/routers/joins.
- Want SwiftUI-style composition + effects?
  - Use `HiveDSL`: `Workflow`, `Node`, `Edge`, `Join`, `Branch`, `Effects`, `ModelTurn`.
- Want model inference via Conduit?
  - Use `HiveConduit` adapter (implements `HiveModelClient`).
- Want durable checkpoints (Wax)?
  - Use `HiveCheckpointWax` adapter (implements `HiveCheckpointStore`).
- Want RAG recall primitives (Wax)?
  - Use `HiveRAGWax` (`WaxRecall`, `HiveRAGSnippet`).
- Want macros to reduce schema boilerplate?
  - Use `HiveMacros` (optional; keep generated code reviewable).

## Core Invariants (Do Not Violate)

- Channel IDs are globally unique per schema; mismatch is fatal.
- `.taskLocal` channels MUST be `.checkpointed` and require a codec path (directly or via `HiveJSONCodec`).
- `.global` channels require a codec when `persistence: .checkpointed`.
- `HiveModelClient.stream(_:)` MUST end with exactly one `.final(...)` chunk, and it MUST be last.
- Determinism depends on stable ordering:
  - Task ordinals, edge lists, join IDs, dictionary key merge order, and event emission rules.

## Recipes (Most Common Things People Build)

### 1) Fan-Out + Join (Map/Reduce)
Use `spawn` (task seeds) to fan out work and a `Join` edge to gate a downstream node until all parents have “seen” the barrier.
- Prefer task-local channels for per-work-item payloads.
- Reducers should encode the aggregation semantics (`append`, `setUnion`, `dictionaryMerge`, etc.).
Read: `references/recipes-fanout-join.md`

### 2) Human Approval Gate (Interrupt/Resume)
Use `interrupt` from a node to stop the run deterministically; later `resume(...)` delivers a `HiveResume` to the first resumed step.
- Interrupt selected by smallest task ordinal in a step.
- An interruption is cleared only after the first committed resumed step (unless re-interrupted in that commit).
Read: `references/recipes-interrupt-resume.md`

### 3) Durable Runs (Checkpointing)
Enable checkpoint policy in `HiveRunOptions` and provide a `checkpointStore` in `HiveEnvironment`.
- Untracked channels are reset to initial values on checkpoint load.
- Checkpoint load validates schema/graph versions and channel fingerprints strictly.
Read: `references/recipes-checkpointing.md`

### 4) Model Turn + Tools
Use `HiveDSL.ModelTurn` or create a node that calls `environment.model`/`environment.modelRouter`, and optionally invokes `environment.tools`.
- Tool definitions use JSON Schema strings; tool calls/results are explicit (`HiveToolCall`, `HiveToolResult`).
Read: `references/recipes-inference-tools.md`

### 5) Deterministic Event Traces (Golden Tests)
If you need golden-testable traces:
- Set `HiveRunOptions(deterministicTokenStreaming: true)`.
- Keep `eventBufferCapacity` high enough, or expect token/debug drops (non-droppable events can still block).
Read: `references/testing-and-determinism.md`

## Troubleshooting Checklist (Fast)

- Compilation fails:
  - Unknown node IDs in edges/routers/joins, duplicate IDs, invalid reserved join characters.
  - Branch missing default (`HiveDSLCompilationError.branchDefaultMissing`).
  - Chain missing start (`HiveDSLCompilationError.chainMissingStart`).
- Runtime fails before step 0:
  - Missing codecs for checkpointed channels (global or task-local).
  - Checkpoint version mismatch / fingerprint mismatch.
- Step aborts with no commit:
  - Unknown channel write, reducer throws, update-policy violation, or checkpoint save failure.
- Model streaming errors:
  - Stream missing `.final`, multiple finals, or token after final.

Read: `references/troubleshooting.md`

## Resources (optional)

### scripts/
- `scripts/hive_api_map.py`: scan a Hive source checkout to list core public entry points (useful when navigating this repo or a vendored copy).

### references/
- `references/mental-model.md`: channel/reducer/superstep/join/interrupt/checkpoint mental model.
- `references/public-api-map.md`: “what to import and when” for each module.
- `references/sharp-edges.md`: invariants, pitfalls, and gotchas.
- `references/runtime-semantics.md`: superstep commit rules, failures, retries/cancellation, external writes, and event/backpressure details.
- `references/dsl-quirks.md`: effects merge rules, branch/chain constraints, and patching limitations.
- `references/recipes-*.md`: end-to-end patterns.
- `references/testing-and-determinism.md`: golden tests, deterministic streaming, and event semantics.
- `references/troubleshooting.md`: symptom → likely cause → fix.
