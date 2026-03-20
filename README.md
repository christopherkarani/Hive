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

LLM agent workflows break in subtle ways: state mutates mid-step, tool calls run in a different order, resume loses context. Hive handles those failure modes with a **deterministic superstep execution model** borrowed from [Bulk Synchronous Parallel](https://en.wikipedia.org/wiki/Bulk_synchronous_parallel).

Run the same graph twice with the same inputs. Get identical output, identical event traces, identical checkpoint bytes. Write golden tests against agent behavior the same way you test a pure function.

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

## How It Works

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

Every superstep is atomic. No node sees another node's writes from the same step. Reducers merge concurrent writes deterministically.

## What You Can Build

- Agent graphs with tool calling, bounded ReAct loops, and token streaming via `AsyncThrowingStream`.
- Human-in-the-loop workflows that interrupt for approval, checkpoint state, and resume with typed payloads.
- Fan-out pipelines where `SpawnEach` dispatches parallel workers and `Join` barriers bring them back together deterministically.
- Hybrid inference paths that route between on-device models and cloud providers without changing execution semantics.
- RAG workflows with `HiveRAGWax`, BM25 ranking, and pluggable memory stores.

## Agent Loop in 5 Lines

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

## Define a Schema

The `@HiveSchema` macro eliminates boilerplate:

```swift
@HiveSchema
enum MySchema: HiveSchema {
    @Channel(reducer: "lastWriteWins()", persistence: "untracked")
    static var _answer: String = ""

    @TaskLocalChannel(reducer: "append()", persistence: "checkpointed")
    static var _logs: [String] = []
}
```

Generates typed channel keys, `channelSpecs`, codecs, and scope configuration.

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

Depend on `HiveCore` alone for zero external dependencies, or `Hive` for batteries-included.

## Status

| Component | Status |
|-----------|--------|
| HiveCore (schema, graph, runtime, store) | **Stable** |
| HiveDSL (workflow result builder) | **Stable** |
| HiveConduit (LLM adapter) | **Stable** |
| HiveCheckpointWax (persistence) | **Stable** |
| HiveRAGWax (vector recall) | **Stable** |
| HiveMacros (@HiveSchema) | **Preview** |
| Distributed execution | Planned |
| Visual graph editor | Planned |
| SwiftUI bindings | Planned |

## Install

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Hive.git", from: "1.0.0")
]

// Target dependency
.product(name: "Hive", package: "Hive")
```

## Documentation

Full docs live at **[christopherkarani.github.io/Hive](https://christopherkarani.github.io/Hive/)**. They cover every module, the DSL grammar, testing patterns, and worked examples.

The runtime behavior is defined by [`HIVE_SPEC.md`](HIVE_SPEC.md). The implementation follows that spec.

## Contributing

Issues and PRs welcome. The [spec](HIVE_SPEC.md) is the source of truth for runtime behavior.

## License

MIT
