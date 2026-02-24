# Building Workflows

Define workflow graphs using the result-builder DSL with nodes, edges, joins, branches, and chains.

## Overview

The ``Workflow`` result builder is the top-level entry point for declarative graph construction. You compose nodes (processing steps) with routing primitives (edges, joins, branches, chains) to define the graph structure, then call `compile()` to produce an executable `CompiledHiveGraph`.

## Workflow

```swift
public struct Workflow<Schema: HiveSchema>: Sendable {
    public init(
        @WorkflowBuilder<Schema> _ content: () -> AnyWorkflowComponent<Schema>
    )
    public func compile() throws -> CompiledHiveGraph<Schema>
}
```

## Node

Nodes are the processing steps of a workflow. Each node receives an input with a store view and returns effects:

```swift
Node("process") { input in
    let value: String = try input.store.get(myKey)
    return Effects {
        Set(resultKey, value.uppercased())
        End()
    }
}.start()  // marks as entry point
```

The `.start()` modifier designates entry-point nodes — these form the initial frontier at superstep 0.

## Routing primitives

### Edge

Static directed edge from one node to another:

```swift
Edge("A", to: "B")
```

### Join

Barrier that waits for all parent nodes to complete before firing the target:

```swift
Join(parents: ["worker1", "worker2"], to: "review")
```

### Chain

Linear sequence of nodes connected by edges:

```swift
Chain {
    Chain.Link.start("A")
    Chain.Link.then("B")
    Chain.Link.then("C")
}
```

This is equivalent to `Edge("A", to: "B")` + `Edge("B", to: "C")`.

### Branch

Conditional routing with named cases:

```swift
Branch(from: "check") {
    Branch.case(name: "high", when: { view in
        (try? view.get(scoreKey)) ?? 0 >= 70
    }) {
        GoTo("pass")
    }
    Branch.default { GoTo("fail") }
}
```

Branches create routers under the hood — they run on post-commit state to determine the next frontier.

### FanOut

Parallel fan-out with optional join barrier:

```swift
FanOut(
    from: "dispatch",
    to: ["workerA", "workerB"],
    joinTo: "merge"
)
```

### SequenceEdges

Shorthand for creating a chain of edges:

```swift
SequenceEdges("A", "B", "C")
// Equivalent to: Edge("A", to: "B"); Edge("B", to: "C")
```

## Complete example

```swift
let workflow = Workflow<MySchema> {
    Node("check") { _ in
        Effects { Set(scoreKey, 85); UseGraphEdges() }
    }.start()

    Node("pass") { _ in
        Effects { Set(resultKey, "passed"); End() }
    }
    Node("fail") { _ in
        Effects { Set(resultKey, "failed"); End() }
    }

    Branch(from: "check") {
        Branch.case(name: "high", when: {
            ($0.get(scoreKey) ?? 0) >= 70
        }) {
            GoTo("pass")
        }
        Branch.default { GoTo("fail") }
    }
}

let graph = try workflow.compile()
```

## DSL grammar summary

```
Workflow<Schema> {
    Node("id") { input -> HiveNodeOutput }.start()
    ModelTurn("id", model:, messages:).tools(.environment).start()
    Subgraph<Parent, Child>("id", childGraph:, input:, env:, output:)

    Edge("from", to: "to")
    Join(parents: ["a", "b"], to: "target")
    Chain { .start("A"); .then("B"); .then("C") }
    Branch(from: "node") {
        Branch.case(name:, when:) { GoTo("x") }
        Branch.default { End() }
    }
    FanOut(from: "src", to: ["a","b"], joinTo: "merge")
    SequenceEdges("A", "B", "C")
}
```
