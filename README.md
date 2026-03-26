# Hive

<p align="center">
  <h1 align="center">Hive</h1>
  <p align="center"><strong>LangGraph for Swift.</strong> Build AI agent workflows that produce byte-identical output on every run.</p>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat&logo=swift&logoColor=white" alt="Swift 6.2">
  <img src="https://img.shields.io/badge/iOS-26%2B-007AFF?style=flat&logo=apple&logoColor=white" alt="iOS 26+">
  <img src="https://img.shields.io/badge/macOS-26%2B-007AFF?style=flat&logo=apple&logoColor=white" alt="macOS 26+">
  <img src="https://img.shields.io/badge/License-MIT-22c55e?style=flat" alt="MIT License">
  <a href="https://christopherkarani.github.io/Hive/"><img src="https://img.shields.io/badge/Docs-Website-58a6ff?style=flat" alt="Documentation"></a>
</p>

---

## The Problem

LLM agent workflows break in subtle ways: state mutates mid-step, tool calls run in a different order, resume loses context. You spend more time debugging than building.

## How Hive Works

Hive uses the **Bulk Synchronous Parallel** model to make agent workflows deterministic. Every superstep is atomic—no node sees another node's writes until the step commits.

```
Schema → Graph → Runtime → Output

  1. Define typed channels          (HiveSchema)
  2. Build a graph via DSL          (Workflow { Node(...) Edge(...) Branch(...) })
  3. Compile to a validated graph   (`.compile()` with cycle detection and SHA-256 versioning)
  4. Execute supersteps:
     ┌─ Frontier nodes run concurrently (lexicographic order)
     ├─ Writes collected, reduced, committed atomically
     ├─ Routers run on post-commit state
     └─ Next frontier scheduled
  5. Repeat until End() or Interrupt()
```

Run the same graph twice with the same inputs. Get identical output, identical event traces, identical checkpoint bytes.

## Key Features

- **Superstep execution**: Atomic commits, no partial state visible mid-step
- **Deterministic by design**: Lexicographic ordering. Same input → byte-identical output every run
- **Typed channels**: `HiveSchema` with reducers (lastWriteWins, append, setUnion), no runtime dicts
- **Fan-out / Join**: `SpawnEach` + `Join` with bitset barriers. Parallel workers, barrier sync, one result
- **Interrupt / Resume**: Typed payloads, checkpoint includes frontier + join barriers + store
- **Swift concurrency**: `async`/`await`, result builders, actors. Data races are compile errors

## Quick Start

```swift
import HiveDSL

Workflow<Schema> {
    Node("classify") { input in
        let text = try input.store.get(Schema.text)
        Effects { Set(Schema.category, classify(text)); UseGraphEdges() }
    }.start()

    Node("respond")  { _ in Effects { End() } }
    Node("escalate") { _ in Effects { End() } }

    Branch(from: "classify") {
        Branch.case(name: "urgent", when: {
            (try? $0.get(Schema.category)) == "urgent"
        }) { GoTo("escalate") }
        Branch.default { GoTo("respond") }
    }
}
```

## Fan-Out, Join, Interrupt

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

## Agent Loop with Tool Calling

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

## Platform Requirements

| Platform | Min Version |
|----------|-------------|
| iOS      | 26.0+       |
| macOS    | 26.0+       |
| Swift    | 6.2         |

## Installation

**Swift Package Manager**

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Hive.git", from: "1.0.0")
]
```

## Architecture

```
HiveCore  (zero external dependencies, pure Swift)
├── HiveDSL             Result-builder workflow DSL
├── HiveConduit          Conduit model client adapter
├── HiveCheckpointWax    Wax-backed checkpoint store
└── HiveRAGWax           Wax-backed RAG snippets

Hive  (umbrella product that re-exports Core, DSL, and adapters)
HiveMacros              @HiveSchema / @Channel / @WorkflowBlueprint
```

## Why Hive?

|  | Hive | LangGraph (Python) | Building from scratch |
|--|------|-------------------|----------------------|
| **Deterministic execution** | Superstep ordering by node ID. Identical traces every run. | Depends on implementation. No structural guarantee. | You build and maintain it yourself. |
| **Type safety** | `HiveSchema` with typed channels, reducers, codecs | Runtime dicts. Errors at execution time. | Whatever you enforce manually. |
| **Concurrency model** | Swift actors + `Sendable`. Data races are compile errors. | GIL + threads. Race conditions are runtime surprises. | Hope and prayer. |
| **Interrupt / Resume** | Typed payloads. Checkpoint includes frontier + join barriers + store. | Checkpoint support varies. | Significant custom work. |
| **Fan-out / Join** | `SpawnEach` + `Join` with bitset barriers. Deterministic merge. | Possible but manual wiring. | Graph theory homework. |
| **On-device inference** | Native support. Route between on-device and cloud models. | Python-only. No on-device story. | Depends on your stack. |
| **Golden testing** | Assert exact event sequences. Graph descriptions produce immutable JSON. | Snapshot testing possible but non-deterministic. | Not practical without determinism. |
| **Swift concurrency** | `async`/`await`, result builders, actors. First-class. | N/A | N/A |

## Try It

```sh
git clone https://github.com/christopherkarani/Hive.git
cd Hive && swift run HiveTinyGraphExample
```

No API keys required. The example runs fan-out workers, a join barrier, and an interrupt/resume cycle in-process.

## Run Tests

```sh
swift test
```

If your environment shows intermittent `swift test` runner hangs, use the stable runner:

```sh
./scripts/swift-test-stable.sh
```

## Documentation

Full documentation at **[christopherkarani.github.io/Hive](https://christopherkarani.github.io/Hive/)** — covers every module, the DSL grammar, testing patterns, and worked examples.

The runtime behavior is defined by [`HIVE_SPEC.md`](HIVE_SPEC.md). The implementation follows that spec.

## Contributing

Issues and PRs welcome. The [spec](HIVE_SPEC.md) is the source of truth for runtime behavior.

## License

MIT
