# Hive Documentation

Hive is a deterministic Swift graph runtime. It provides typed schemas, reducers, graph building, routing, fan-out/join, checkpoint protocols, interrupts/resume, replay-friendly events, stores, cache/retry/run options, and a tiny `Hive` umbrella module that re-exports `HiveCore`.

This package intentionally does not ship a workflow DSL, model/tool calling APIs, RAG memory, Conduit adapters, or Wax adapters.

## Modules

| Module | Purpose |
| --- | --- |
| `HiveCore` | Core runtime surface: schema, channels, reducers, graph builder, runtime, checkpoints, events, stores, cache, retry, run options |
| `Hive` | Umbrella module that only re-exports `HiveCore` |
| `HiveTinyGraphExample` | Executable example covering fan-out, task-local state, join, interrupt, checkpoint, and resume |

## Quick Start

```sh
swift package describe
swift build --target HiveCore
swift build --target Hive
swift run HiveTinyGraphExample
swift test --filter HiveCoreTests
```

## Minimal Graph

```swift
import HiveCore

var builder = HiveGraphBuilder<MySchema>(start: [HiveNodeID("A")])

builder.addNode(HiveNodeID("A")) { _ in
    HiveNodeOutput(next: .useGraphEdges)
}

builder.addNode(HiveNodeID("B")) { _ in
    HiveNodeOutput(next: .end)
}

builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))

let graph = try builder.compile()
let runtime = try HiveRuntime(graph: graph, environment: environment)
```

## Runtime Model

Hive executes graphs in deterministic supersteps:

1. The current frontier runs concurrently.
2. Writes are collected and reduced in deterministic order.
3. The committed store becomes visible.
4. Routers schedule the next frontier from committed state.
5. Checkpoints and interrupts preserve enough runtime state to resume safely.

The event stream is runtime-focused. Core events include graph/run lifecycle, supersteps, tasks, writes, checkpoints, interrupts, resumes, cache/retry behavior, and `customDebug` for user-defined observations.
