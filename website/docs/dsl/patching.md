---
sidebar_position: 3
title: Workflow Patching
description: WorkflowPatch and WorkflowDiff for mutating compiled graphs without full recompilation.
---

# Workflow Patching

Mutate compiled graphs without full recompilation using `WorkflowPatch`.

## WorkflowPatch

```swift
var patch = WorkflowPatch<Schema>()
patch.replaceNode("B") { input in Effects { End() } }
patch.insertProbe("monitor", between: "A", and: "B") { input in
    Effects { Set(probeKey, "observed"); UseGraphEdges() }
}
let result = try patch.apply(to: graph)
// result.graph — new compiled graph
// result.diff — WorkflowDiff with changes summary
```

## Available Operations

### Replace Node

Swap out a node's implementation while preserving all edges:

```swift
patch.replaceNode("nodeID") { input in
    // New implementation
    Effects { End() }
}
```

### Insert Probe

Insert a monitoring node between two connected nodes:

```swift
patch.insertProbe("probeName", between: "A", and: "B") { input in
    Effects {
        Set(probeKey, "observed")
        UseGraphEdges()
    }
}
```

The probe intercepts the edge from A to B, creating the chain `A → probe → B`.

## WorkflowDiff

The result of applying a patch includes a `WorkflowDiff` that summarizes what changed:

```swift
let result = try patch.apply(to: graph)
let diff = result.diff
// Inspect changes: added nodes, removed edges, replaced implementations, etc.
```

## Use Cases

- **A/B testing** — Swap node implementations between variants
- **Observability** — Insert probes to monitor intermediate state
- **Hot patching** — Update behavior without rebuilding the entire graph
- **Testing** — Replace real implementations with mocks
