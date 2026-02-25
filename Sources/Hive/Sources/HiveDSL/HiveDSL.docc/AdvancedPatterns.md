# Advanced Patterns

Compose workflows with subgraphs, patches, blueprints, and fan-out patterns.

## Overview

Beyond basic nodes and routing, HiveDSL provides advanced composition patterns: nested subgraphs for modular workflows, patches for mutating compiled graphs, blueprints for reusable workflow fragments, and fan-out patterns for parallel processing.

## Subgraph

``Subgraph`` embeds a child workflow inside a parent workflow. The child runs to completion as a single node in the parent graph, with explicit input and output mappings:

```swift
Subgraph<ParentSchema, ChildSchema>(
    "sub",
    childGraph: childGraph,
    inputMapping: { parentStore in
        try parentStore.get(inputKey)
    },
    environmentMapping: { _ in childEnv },
    outputMapping: { _, childStore in
        [AnyHiveWrite(
            parentResultKey,
            try childStore.get(childResultKey)
        )]
    }
)
```

The input mapping reads from the parent store to produce the child's input. The output mapping reads from the child's final store to produce writes back into the parent.

## WorkflowPatch

``WorkflowPatch`` mutates compiled graphs without full recompilation. This is useful for testing, A/B experiments, or runtime customization:

### Replace a node

```swift
var patch = WorkflowPatch<Schema>()
patch.replaceNode("B") { input in
    Effects { End() }
}
let result = try patch.apply(to: graph)
```

### Insert a probe

Insert an observation node between two existing nodes:

```swift
var patch = WorkflowPatch<Schema>()
patch.insertProbe(
    "monitor",
    between: "A",
    and: "B"
) { input in
    Effects {
        Set(probeKey, "observed")
        UseGraphEdges()
    }
}
let result = try patch.apply(to: graph)
```

### WorkflowDiff

The result of applying a patch includes a ``WorkflowDiff`` with a summary of changes:

```swift
let result = try patch.apply(to: graph)
// result.graph — new compiled graph
// result.diff — WorkflowDiff with changes summary
```

## WorkflowBlueprint

``WorkflowBlueprint`` defines composable workflow fragments using a SwiftUI-style protocol:

```swift
public protocol WorkflowBlueprint: WorkflowComponent {
    associatedtype Body: WorkflowComponent
        where Body.Schema == Schema
    @WorkflowBuilder<Schema> var body: Body { get }
}
```

Use blueprints to encapsulate reusable patterns:

```swift
struct ReviewPattern<Schema: HiveSchema>: WorkflowBlueprint {
    @WorkflowBuilder<Schema>
    var body: some WorkflowComponent<Schema> {
        Node("review") { _ in
            Effects { Interrupt("Approve?") }
        }
        Node("approved") { _ in Effects { End() } }
        Edge("review", to: "approved")
    }
}
```

Then compose into a workflow:

```swift
let workflow = Workflow<Schema> {
    Node("start") { _ in
        Effects { UseGraphEdges() }
    }.start()

    ReviewPattern<Schema>()

    Edge("start", to: "review")
}
```

## Fan-out patterns

### SpawnEach with join

The most common fan-out pattern spawns parallel tasks and collects results with a join barrier:

```swift
let workflow = Workflow<Schema> {
    Node("dispatch") { _ in
        Effects {
            SpawnEach(items, node: "worker") { item in
                var local = HiveTaskLocalStore<Schema>.empty
                try! local.set(itemKey, item)
                return local
            }
            End()
        }
    }.start()

    Node("worker") { input in
        let item: String = try input.store.get(itemKey)
        return Effects {
            Append(resultsKey, elements: [item.uppercased()])
            End()
        }
    }

    Node("merge") { input in
        let results = try input.store.get(resultsKey)
        return Effects {
            Set(summaryKey, results.joined(separator: ", "))
            End()
        }
    }

    Join(parents: ["worker"], to: "merge")
}
```

### FanOut shorthand

For simpler cases where workers are predefined nodes:

```swift
FanOut(
    from: "dispatch",
    to: ["workerA", "workerB", "workerC"],
    joinTo: "merge"
)
```

This creates edges from `dispatch` to each worker and a join barrier from all workers to `merge`.
