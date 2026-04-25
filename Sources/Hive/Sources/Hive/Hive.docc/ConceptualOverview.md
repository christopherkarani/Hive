# Conceptual Overview

Hive is a deterministic graph runtime built around the Bulk Synchronous Parallel model.

## Architecture

```text
Hive      re-exports HiveCore
HiveCore  schemas, graph compiler, runtime, events, checkpoint protocols
```

## Supersteps

Each superstep has three phases:

1. Frontier nodes execute concurrently from a pre-step snapshot.
2. Writes are reduced and committed atomically.
3. Routers, static edges, spawns, and join barriers assemble the next frontier.

Nodes never observe same-step writes from other nodes.

## Determinism

Hive keeps execution reproducible through lexicographic node ordering, stable task ordinals, deterministic IDs, sorted channel iteration, and atomic commits. The same graph and input produce the same state transitions and event trace.

## Use Cases

- Fan-out/join processing
- Resumable pipelines
- Human approval gates with interrupt/resume
- Runtime workflows that need golden-test-level reproducibility
