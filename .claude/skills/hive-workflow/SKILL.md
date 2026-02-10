---
name: hive-workflow
description: "Create a Hive workflow using the DSL — nodes, edges, joins, branches, and chains. Generates both DSL and imperative HiveGraphBuilder versions."
user-invocable: true
argument-hint: "[workflow-description]"
---

# Hive Workflow Scaffolding

Generate a complete workflow definition using Hive's DSL and equivalent imperative builder.

## Step 1: Gather Workflow Structure

Determine:
- **Nodes**: What processing steps exist? Each node reads from channels and writes results
- **Edges**: How do nodes connect? (static edges, conditional routing, fan-out)
- **Joins**: Do any nodes need to wait for multiple predecessors?
- **Branching**: Are there conditional paths based on channel state?
- **Start nodes**: Which nodes execute first?

## Step 2: Generate DSL Version

```swift
import HiveCore
import HiveDSL

// Assuming Schema is defined elsewhere
let workflow = Workflow<Schema> {
    // Start node — marked with .start()
    Node("process") { input in
        let messages = input.read(Schema.messagesKey)
        return HiveNodeOutput(
            writes: [AnyHiveWrite(Schema.messagesKey, messages + ["processed"])],
            next: .useGraphEdges
        )
    }
    .start()

    // Conditional branching via Edge with router
    Edge(from: "process") { store in
        let count = store.read(Schema.counterKey)
        if count > 5 {
            return .goto([HiveNodeID("summarize")])
        }
        return .goto([HiveNodeID("continue")])
    }

    Node("continue") { input in
        HiveNodeOutput(
            writes: [AnyHiveWrite(Schema.counterKey, 1)],
            next: .useGraphEdges
        )
    }

    Edge(from: "continue", to: "process") // loop back

    Node("summarize") { input in
        let messages = input.read(Schema.messagesKey)
        return HiveNodeOutput(
            writes: [AnyHiveWrite(Schema.summaryKey, messages.joined(separator: "\n"))],
            next: .end
        )
    }
}

let graph = try workflow.compile()
```

## Step 3: Generate Equivalent HiveGraphBuilder Version

```swift
var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("process")])

builder.addNode(HiveNodeID("process")) { input in
    let messages = input.read(Schema.messagesKey)
    return HiveNodeOutput(
        writes: [AnyHiveWrite(Schema.messagesKey, messages + ["processed"])],
        next: .useGraphEdges
    )
}

builder.addEdge(from: HiveNodeID("process")) { store in
    let count = store.read(Schema.counterKey)
    if count > 5 {
        return .goto([HiveNodeID("summarize")])
    }
    return .goto([HiveNodeID("continue")])
}

builder.addNode(HiveNodeID("continue")) { input in
    HiveNodeOutput(
        writes: [AnyHiveWrite(Schema.counterKey, 1)],
        next: .useGraphEdges
    )
}

builder.addEdge(from: HiveNodeID("continue"), to: HiveNodeID("process"))

builder.addNode(HiveNodeID("summarize")) { input in
    let messages = input.read(Schema.messagesKey)
    return HiveNodeOutput(
        writes: [AnyHiveWrite(Schema.summaryKey, messages.joined(separator: "\n"))],
        next: .end
    )
}

let graph = try builder.compile()
```

## DSL Components Reference

| Component | Purpose | Example |
|-----------|---------|---------|
| `Node("id") { ... }` | Processing step | Read channels, produce writes |
| `.start()` | Mark as entry point | `Node("init") { ... }.start()` |
| `Edge(from:to:)` | Static edge | `Edge(from: "A", to: "B")` |
| `Edge(from:) { router }` | Conditional routing | Router returns `.goto([...])` |
| `Join(sources:target:)` | Wait for all sources | Barrier synchronization |
| `Chain("A", "B", "C")` | Sequential pipeline | Sugar for A→B→C edges |
| `Branch(from:) { ... }` | Multi-way conditional | Multiple edge targets |

## Key Rules

- Routers are **synchronous**: `@Sendable (HiveStoreView<Schema>) -> HiveNext`
- Node IDs must not contain `:` or `+` (reserved for join edges)
- `.next` options: `.useGraphEdges`, `.goto([nodeIDs])`, `.end`, `.spawn(tasks)`
- Nodes marked `.start()` execute in the first superstep
- All writes are collected and committed atomically after frontier tasks complete
- See HIVE_SPEC.md §9 for graph builder normative requirements
