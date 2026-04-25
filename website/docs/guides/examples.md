---
title: Examples
description: Core graph runtime examples.
---

# Examples

## Minimal Graph

```swift
var builder = HiveGraphBuilder<MySchema>(start: [HiveNodeID("A")])
builder.addNode(HiveNodeID("A")) { _ in
    HiveNodeOutput(next: .end)
}
let graph = try builder.compile()
```

## Static Edge

```swift
builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .useGraphEdges) }
builder.addNode(HiveNodeID("B")) { _ in HiveNodeOutput(next: .end) }
builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))
```

## Router

```swift
builder.addRouter(from: HiveNodeID("classify")) { store in
    let category = try store.get(MySchema.category)
    return category == "urgent" ? .to([HiveNodeID("escalate")]) : .to([HiveNodeID("reply")])
}
```

## Tiny Graph

Run the included example:

```sh
swift run HiveTinyGraphExample
```

It demonstrates fan-out, task-local state, a join barrier, interrupt, checkpoint, and resume.
