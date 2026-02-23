---
sidebar_position: 1
title: Overview
description: Introduction to Hive — a deterministic graph runtime for agent workflows in Swift.
---

# Overview

Hive is the Swift equivalent of LangGraph — a deterministic graph runtime for building agent workflows. It executes workflows as **superstep graphs** where frontier nodes run concurrently, writes commit atomically, and routers schedule the next frontier.

## Why Hive?

- **Deterministic** — BSP supersteps with lexicographic ordering. Every run produces identical event traces.
- **Swift-native** — Actors, `Sendable`, `async`/`await`, result builders. No Python, no YAML, no runtime reflection.
- **Agent-ready** — Tool calling, bounded agent loops, streaming tokens, fan-out/join patterns, and hybrid inference.
- **Resumable** — Interrupt a workflow for human approval. Checkpoint state. Resume with typed payloads.

## Requirements

- Swift 6.2 toolchain
- iOS 26+ / macOS 26+

## Quick Start

```bash
swift build                              # Build all targets
swift test                               # Run all tests
swift test --filter HiveCoreTests        # Run a single test target
swift run HiveTinyGraphExample           # Run the example executable
```

## 30-Second Example

```swift
import HiveDSL

let workflow = Workflow<MySchema> {
    Node("classify") { input in
        let text = try input.store.get(MySchema.text)
        Effects {
            Set(MySchema.category, classify(text))
            UseGraphEdges()
        }
    }.start()

    Node("respond") { _ in Effects { End() } }
    Node("escalate") { _ in Effects { End() } }

    Branch(from: "classify") {
        Branch.case(name: "urgent", when: {
            (try? $0.get(MySchema.category)) == "urgent"
        }) {
            GoTo("escalate")
        }
        Branch.default { GoTo("respond") }
    }
}

let graph = try workflow.compile()
let runtime = HiveRuntime(graph: graph, environment: env)
```

## How It Works

```
Schema → Graph → Runtime → Output

  1. Define typed channels          (HiveSchema)
  2. Build a graph via DSL          (Workflow { Node(...) Edge(...) Branch(...) })
  3. Compile to validated graph     (.compile() — cycle detection, SHA-256 versioning)
  4. Execute supersteps:
     ┌─ Frontier nodes run concurrently (lexicographic order)
     ├─ Writes collected, reduced, committed atomically
     ├─ Routers run on post-commit state
     └─ Next frontier scheduled
  5. Repeat until End() or Interrupt()
```

Every superstep is atomic. No node sees another node's writes from the same step. Reducers merge concurrent writes deterministically.
