---
sidebar_position: 1
title: DSL Overview
description: Workflow result builder, Node, Edge, Branch, Chain, Join, FanOut, and Effects DSL.
---

# HiveDSL Overview

## Workflow Result Builder

The top-level entry point:

```swift
public struct Workflow<Schema: HiveSchema>: Sendable {
    public init(@WorkflowBuilder<Schema> _ content: () -> AnyWorkflowComponent<Schema>)
    public func compile() throws -> CompiledHiveGraph<Schema>
}
```

## Node Definition

```swift
Node("process") { input in
    let value: String = try input.store.get(myKey)
    return Effects {
        Set(resultKey, value.uppercased())
        End()
    }
}.start()  // marks as entry point
```

## Effects DSL

Effects accumulate writes, spawn seeds, routing, and interrupt requests:

| Primitive | Purpose |
|-----------|---------|
| `Set(key, value)` | Write a value to a channel |
| `Append(key, elements: [...])` | Append to a collection channel |
| `GoTo("node")` | Route to a specific node |
| `UseGraphEdges()` | Follow statically declared edges |
| `End()` | Terminate the workflow |
| `Interrupt(payload)` | Pause execution, save checkpoint |
| `SpawnEach(items, node:, local:)` | Fan-out: spawn parallel tasks |

## Routing Primitives

### Edge — Static Directed Edge

```swift
Edge("A", to: "B")
```

### Join — Barrier

Waits for all parents to complete before firing:

```swift
Join(parents: ["worker"], to: "review")
```

### Chain — Linear Sequence

```swift
Chain {
    Chain.Link.start("A")
    Chain.Link.then("B")
    Chain.Link.then("C")
}
```

### Branch — Conditional Routing

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

### FanOut — Parallel with Optional Join

```swift
FanOut(from: "dispatch", to: ["workerA", "workerB"], joinTo: "merge")
```

### SequenceEdges — Shorthand Chain

```swift
SequenceEdges("A", "B", "C")
```

## DSL Grammar Summary

```swift
Workflow<Schema> {
    Node("id") { input -> HiveNodeOutput }.start()
    ModelTurn("id", model:, messages:).tools(.environment).start()
    Subgraph<Parent, Child>("id", childGraph:, input:, env:, output:).start()

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

// Inside nodes:
Effects {
    Set(key, value); Append(key, elements: [...])
    GoTo("node"); UseGraphEdges(); End()
    Interrupt(payload)
    SpawnEach(items, node: "worker") { item in localStore }
}
```
