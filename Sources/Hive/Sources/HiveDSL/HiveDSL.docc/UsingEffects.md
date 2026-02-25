# Using Effects

Accumulate writes, routing decisions, spawn seeds, and interrupt requests with the Effects builder.

## Overview

The `Effects` builder is how nodes express their output — what to write, where to route next, and whether to interrupt. Effects accumulate write operations and routing decisions into a `HiveNodeOutput` that the runtime processes during the commit phase.

## The Effects builder

```swift
Node("worker") { input in
    let item: String = try input.store.get(itemKey)
    return Effects {
        Set(resultKey, item.uppercased())
        Append(logKey, elements: ["processed \(item)"])
        GoTo("next")
    }
}
```

## Write effects

### Set

Write a value to a channel, replacing the current value through the channel's reducer:

```swift
Set(MySchema.category, "urgent")
```

### Append

Append elements to a collection channel:

```swift
Append(MySchema.messages, elements: ["new message"])
```

## Routing effects

### GoTo

Route to a specific node:

```swift
GoTo("targetNode")
```

### UseGraphEdges

Follow statically declared edges from the current node:

```swift
UseGraphEdges()
```

### End

Terminate the workflow from this node:

```swift
End()
```

## Interrupt

Pause execution and save a checkpoint with a typed payload:

```swift
Interrupt("Please approve these results")
```

The runtime selects the interrupt from the lowest-ordinal task when multiple nodes interrupt in the same superstep.

## SpawnEach

Fan out to parallel workers with task-local state:

```swift
SpawnEach(["a", "b", "c"], node: "worker") { item in
    var local = HiveTaskLocalStore<Schema>.empty
    try! local.set(MySchema.Channels.item, item)
    return local
}
```

Each spawned task gets its own `HiveTaskLocalStore` overlay, isolated from siblings. The tasks execute in the next superstep and can be collected with a ``Join`` barrier.

## Combining effects

Effects can be freely combined in a single builder:

```swift
Effects {
    Set(statusKey, "processing")
    Append(logKey, elements: ["started"])
    Set(counterKey, count + 1)
    UseGraphEdges()
}
```

Write effects are collected and applied during the atomic commit phase. Routing effects determine the next frontier. If both `GoTo` and `UseGraphEdges` are present, the explicit routing takes precedence.

## Complete example: fan-out, join, interrupt

```swift
let workflow = Workflow<Schema> {
    Node("dispatch") { _ in
        Effects {
            SpawnEach(["a", "b", "c"], node: "worker") { item in
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

    Node("review") { _ in
        Effects { Interrupt("Approve results?") }
    }

    Node("done") { _ in Effects { End() } }

    Join(parents: ["worker"], to: "review")
    Edge("review", to: "done")
}
```
