---
title: Introduction
description: Hive is a deterministic graph runtime for Swift.
---

# Introduction

Hive is a deterministic Swift graph runtime. It executes typed graphs as supersteps: frontier nodes run concurrently, writes are gathered, reducers merge updates, and the commit becomes visible only at the next step.

Hive is focused on runtime semantics. The package contains graph building, schemas, reducers, routing, joins, checkpoint protocols, interrupts/resume, and event streams.

```swift
import Hive

var builder = HiveGraphBuilder<MySchema>(start: [HiveNodeID("start")])
builder.addNode(HiveNodeID("start")) { input in
    HiveNodeOutput(next: .end)
}
let graph = try builder.compile()
```

## Why Use Hive

- Atomic superstep commits
- Deterministic task and event ordering
- Typed channel state with explicit reducers
- Fan-out and join barriers
- Interrupt/resume and checkpoint protocol support
- Linux-capable core runtime with Swift 6.2
