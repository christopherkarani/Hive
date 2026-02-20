# Hive

**Deterministic graph runtime for agent workflows in Swift.**

![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange) ![iOS 26+](https://img.shields.io/badge/iOS-26%2B-blue) ![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue) ![License](https://img.shields.io/badge/License-MIT-green)

Hive runs agent workflows as deterministic superstep graphs. Same input, same output, every time — golden-testable, checkpoint-resumable, and built entirely on Swift concurrency.

## Why Hive?

- **Deterministic** — BSP supersteps with lexicographic ordering. Every run produces identical event traces. Write golden tests against agent behavior.
- **Swift-native** — Actors, `Sendable`, `async`/`await`, result builders. No Python, no YAML, no runtime reflection.
- **Agent-ready** — Tool calling, bounded agent loops, streaming tokens, fan-out/join patterns, and hybrid inference (on-device + cloud).
- **Resumable** — Interrupt a workflow for human approval. Checkpoint state. Resume with typed payloads. No lost context.

 ## 30-Second Example

A workflow that classifies input and branches to different handlers:

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

## What You Can Build

- Multi-step agent graphs with fan-out, joins, and tool-approval gates
- Human-in-the-loop workflows that pause for review and resume reliably
- RAG pipelines with on-device vector recall via `HiveRAGWax`
- Hybrid inference: on-device models + cloud fallback with deterministic routing
- SwiftUI apps with streaming agent output via `AsyncThrowingStream`

## Core Concepts

| Concept | What it does |
|---------|-------------|
| **Schema** | Declares typed channels with reducers, scopes, and codecs |
| **Node** | Async function that reads state and returns writes + routing |
| **Superstep** | All frontier nodes run concurrently, then commit atomically |
| **Channel** | Typed state slot — global (shared) or task-local (per fan-out) |
| **Reducer** | Deterministic merge when multiple nodes write the same channel |
| **Interrupt** | Pause the workflow, save a checkpoint, wait for human input |
| **Router** | Synchronous branching on fresh post-commit state |

## Examples

### Minimal — Hello World

```swift
Workflow<Schema> {
    Node("greet") { _ in
        Effects {
            Set(Schema.message, "Hello from Hive!")
            End()
        }
    }.start()
}
```

### Branching — Route by State

```swift
Workflow<Schema> {
    Node("check") { _ in
        Effects { Set(Schema.score, 85); UseGraphEdges() }
    }.start()

    Node("pass") { _ in Effects { End() } }
    Node("fail") { _ in Effects { End() } }

    Branch(from: "check") {
        Branch.case(name: "high", when: {
            (try? $0.get(Schema.score)) ?? 0 >= 70
        }) {
            GoTo("pass")
        }
        Branch.default { GoTo("fail") }
    }
}
```

### Agent Loop — LLM with Tools

```swift
Workflow<Schema> {
    ModelTurn("chat", model: "claude-sonnet-4-5-20250929", messages: [
        HiveChatMessage(id: "u1", role: .user, content: "Weather in SF?")
    ])
    .tools(.environment)
    .agentLoop()
    .writes(to: Schema.answer)
    .start()
}
```

### Fan-out, Join, Interrupt

Parallel workers, barrier sync, then human approval:

```swift
Workflow<Schema> {
    Node("dispatch") { _ in
        Effects {
            SpawnEach(["a", "b", "c"], node: "worker") { item in
                var local = HiveTaskLocalStore<Schema>.empty
                try local.set(Schema.item, item)
                return local
            }
            End()
        }
    }.start()

    Node("worker") { input in
        let item = try input.store.get(Schema.item)
        Effects { Append(Schema.results, elements: [item.uppercased()]); End() }
    }

    Node("review") { _ in Effects { Interrupt("Approve results?") } }
    Node("done")   { _ in Effects { End() } }

    Join(parents: ["worker"], to: "review")
    Edge("review", to: "done")
}
```

## Macros

The `@HiveSchema` macro eliminates channel boilerplate. Write this:

```swift
@HiveSchema
enum MySchema: HiveSchema {
    @Channel(reducer: "lastWriteWins()", persistence: "untracked")
    static var _answer: String = ""

    @TaskLocalChannel(reducer: "append()", persistence: "checkpointed")
    static var _logs: [String] = []
}
```

The macro generates typed `HiveChannelKey` properties, `channelSpecs`, codecs, and scope configuration — roughly 20 lines of code you never have to write or maintain.

## Architecture

```
HiveCore  (zero external deps — pure Swift)
├── HiveDSL             result-builder workflow DSL
├── HiveConduit          Conduit model client adapter
├── HiveCheckpointWax    Wax-backed checkpoint store
└── HiveRAGWax           Wax-backed RAG snippets

Hive  (umbrella — re-exports Core + DSL + Conduit + CheckpointWax)
HiveMacros              @HiveSchema / @Channel / @WorkflowBlueprint
```

`HiveCore` has zero external dependencies. Adapters bring in only what they need. You can depend on `HiveCore` alone for maximum control, or `Hive` for batteries-included.

## Getting Started

### Add to your project

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Hive.git", from: "1.0.0")
]

// Target dependency
.product(name: "Hive", package: "Hive")
```

### Build and test

```sh
swift build
swift test
swift run HiveTinyGraphExample
```

### Run a single test target

```sh
swift test --filter HiveCoreTests
swift test --filter HiveDSLTests
```

## Specification

Hive's behavior is defined by a normative specification: [`HIVE_SPEC.md`](HIVE_SPEC.md). The spec covers execution semantics, checkpoint format, interrupt/resume protocol, and determinism guarantees. Implementation follows the spec — not the other way around.

## Roadmap

- [ ] Distributed execution across multiple devices
- [ ] Visual graph editor with live state inspection
- [ ] SwiftUI bindings for real-time workflow observation
- [ ] Pre-built agent templates (ReAct, Plan-and-Execute, Reflection)

## Contributing

Issues and PRs are welcome. The spec ([`HIVE_SPEC.md`](HIVE_SPEC.md)) is the source of truth for runtime behavior.

If Hive is useful to you, a star helps others find it.

## License

MIT
