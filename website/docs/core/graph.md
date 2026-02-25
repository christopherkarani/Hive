---
sidebar_position: 3
title: Graph Compilation
description: HiveGraphBuilder, compile validation, graph description, and Mermaid export.
---

# Graph Compilation

## HiveGraphBuilder

The imperative API for constructing graphs:

```swift
var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])

builder.addNode(HiveNodeID("A")) { input in
    HiveNodeOutput(
        writes: [AnyHiveWrite(key, value)],
        next: .useGraphEdges
    )
}

builder.addNode(HiveNodeID("B")) { _ in HiveNodeOutput(next: .end) }
builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))
builder.addJoinEdge(parents: [HiveNodeID("W1"), HiveNodeID("W2")], target: HiveNodeID("Gate"))
builder.addRouter(from: HiveNodeID("A")) { storeView in .nodes([HiveNodeID("B")]) }

let graph = try builder.compile()
```

## CompiledHiveGraph

The validated, immutable, executable graph:

```swift
public struct CompiledHiveGraph<Schema: HiveSchema>: Sendable {
    public let start: [HiveNodeID]
    public let staticLayersByNodeID: [HiveNodeID: Int]
    public let maxStaticDepth: Int
    // ... internal: nodes, edges, routers, join edges, version hash
}
```

## Graph Validation

`compile()` validates:
- No duplicate node IDs
- All edge targets reference existing nodes
- Start nodes exist in the graph
- No cycles in static edges (throws `staticGraphCycleDetected`)
- Router-only cycles are allowed (they're dynamic)

## Graph Description

`graphDescription()` produces a deterministic JSON representation with a SHA-256 version hash. Identical graphs always produce identical JSON — enabling golden tests.

## Mermaid Export

`HiveGraphMermaidExporter.export(description)` converts a graph description to a Mermaid flowchart for visualization:

```
flowchart TD
    Start --> WorkerA
    Start --> WorkerB
    WorkerA --> Gate
    WorkerB --> Gate
    Gate --> Finalize
```

## Static Layer Analysis

The compiler computes static layer depths via topological ordering. This enables optimizations and visualization of the graph's parallel structure.
