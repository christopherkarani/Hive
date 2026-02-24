# ``Hive``

Deterministic graph runtime for agent workflows in Swift.

@Metadata {
    @DisplayName("Hive")
}

## Overview

Hive runs agent workflows as deterministic superstep graphs using the Bulk Synchronous Parallel (BSP) model. Same input, same output, every time — golden-testable, checkpoint-resumable, and built entirely on Swift concurrency.

Hive is the Swift equivalent of LangGraph: a deterministic graph runtime for building agent workflows. Frontier nodes run concurrently, writes commit atomically, and routers schedule the next frontier.

**Why Hive?**

- **Deterministic** — BSP supersteps with lexicographic ordering. Every run produces identical event traces.
- **Swift-native** — Actors, `Sendable`, `async`/`await`, result builders. No Python, no YAML, no runtime reflection.
- **Agent-ready** — Tool calling, bounded agent loops, streaming tokens, fan-out/join patterns, and hybrid inference.
- **Resumable** — Interrupt a workflow for human approval. Checkpoint state. Resume with typed payloads.

### Requirements

- Swift 6.2 toolchain
- iOS 26+ / macOS 26+

### Quick Example

```swift
import Hive

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

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:ConceptualOverview>
