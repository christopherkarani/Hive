# Hive

**Deterministic agent workflow runtime for Swift.**

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2026%20%7C%20macOS%2026-blue.svg)](https://developer.apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](../../LICENSE)

---

LLM workflows break in subtle ways — state mutated mid-step, non-deterministic fan-out, no way to pause for human review without losing context. Hive fixes this with a formal execution model borrowed from parallel computing.

**Every node in a step runs concurrently. Writes are held until all nodes finish. Commit is atomic.** The next step sees a clean, consistent snapshot. Run the same graph twice with the same inputs — you get byte-identical output.

---

## What it looks like

```swift
import HiveDSL

let workflow = Workflow<Schema> {
    Node("triage") { input in
        Effects {
            Set(Schema.status, classify(input.store.get(Schema.message)))
            GoTo("respond")
        }
    }.start()

    ModelTurn("respond", model: "gpt-4o") { store in
        [HiveChatMessage(id: "u1", role: .user, content: store.get(Schema.message))]
    }
    .tools(.environment)
    .writes(to: Schema.reply)
    .agentLoop()                 // bounded model/tool loop, deterministic tool ordering

    Branch(from: "respond") {
        Branch.case(name: "escalate", when: { store in
            store.get(Schema.reply).contains("refund")
        }) {
            GoTo("human_review")
        }
        Branch.default { UseGraphEdges() }
    }

    Node("human_review") { _ in
        Effects { Interrupt(HumanPayload()) }   // pause, checkpoint, resume later
    }

    Node("done") { _ in Effects { End() } }
    Edge("respond", to: "done")
}
```

Run it:

```swift
let runtime = try HiveRuntime(graph: workflow.compile(), environment: env)
let handle  = await runtime.run(threadID: "thread-1", input: userInput, options: HiveRunOptions())

for try await event in handle.events { /* stream token events, step completions */ }
let outcome = try await handle.outcome.value
// .finished / .interrupted(id, payload) / .outOfSteps / .cancelled
```

Resume after human review:

```swift
let handle = await runtime.resume(
    threadID: "thread-1",
    interruptID: interruptID,
    payload: HumanPayload(approved: true),   // HumanPayload == Schema.ResumePayload
    options: HiveRunOptions()
)
```

---

## How it works

```
Step N   ┌─────────┐  ┌─────────┐  ┌─────────┐
         │ Node A  │  │ Node B  │  │ Node C  │   ← concurrent
         └────┬────┘  └────┬────┘  └────┬────┘
              │  writes    │  writes    │  writes
              └────────────┴────────────┘
                           │
                    ATOMIC COMMIT                 ← reducers fold writes,
                           │                        versions bump
Step N+1         ┌─────────┴──────────┐
               Node D              Node E         ← see post-commit state
```

- **Channels** — typed state slots with a scope (global or task-local), reducer, and optional codec for checkpointing.
- **Reducers** — `lastWriteWins`, `append`, `setUnion`, `dictionaryMerge` — fold concurrent writes deterministically.
- **Fan-out / Join** — `SpawnEach` creates N parallel tasks with task-local state; `Join` fires when all parents complete.
- **Interrupt / Resume** — any node returns `Interrupt(payload)`. Runtime checkpoints state and returns `.interrupted`. Resume reloads from checkpoint; payload is delivered exactly once to the next step.

---

## Try it now

```sh
git clone https://github.com/christopherkarani/hive
swift run HiveTinyGraphExample
```

The example runs a fan-out across 3 parallel workers, waits at a join barrier, fires an interrupt, saves a checkpoint, and resumes — all in ~100 lines with no model client required.

---

## Why Hive

|  | Hive | ad-hoc async/await | LangGraph (Python) |
|--|------|-------------------|--------------------|
| Step atomicity | ✅ BSP write barrier | ❌ no guarantee | ✅ |
| Typed state | ✅ channels + reducers | ❌ untyped | ⚠️ TypedDict |
| Interrupt / resume | ✅ checkpointed | ❌ manual | ✅ |
| Swift 6 strict concurrency | ✅ | ⚠️ manual | ❌ N/A |
| On-device inference (Foundation Models) | ✅ | ✅ | ❌ N/A |
| Deterministic replay | ✅ byte-identical | ❌ | ⚠️ |

---

## Installation

```swift
// Package.swift
.package(url: "https://github.com/christopherkarani/hive", from: "0.1.0"),
```

```swift
// Target dependencies
.product(name: "Hive", package: "hive")       // full stack
.product(name: "HiveDSL", package: "hive")    // DSL only, no adapters
.product(name: "HiveCore", package: "hive")   // minimal runtime, zero external deps
```

Requires Swift 6.2 · iOS 26+ · macOS 26+

---

## Modules

| Module | What it provides |
|--------|-----------------|
| `HiveCore` | Schema, graph builder, runtime, all core types — zero external deps |
| `HiveDSL` | `Workflow` / `Node` / `Branch` / `ModelTurn` / `Subgraph` / `WorkflowPatch` |
| `HiveConduit` | Adapter for any [Conduit](https://github.com/PreternaturalAI/Conduit) `TextGenerator` (OpenAI, Anthropic, …) |
| `HiveCheckpointWax` | Durable WAL-backed checkpoint store via [Wax](https://github.com/PreternaturalAI/Wax) |
| `HiveRAGWax` | Namespace-scoped memory with recall |
| `Hive` | Umbrella re-export of all of the above — one import |

---

## Define a schema

Channels are declared once on a `HiveSchema` enum:

```swift
enum Schema: HiveSchema {
    typealias Context = Void
    typealias Input   = String

    static let message = HiveChannelKey<Schema, String>(HiveChannelID("message"))
    static let reply   = HiveChannelKey<Schema, String>(HiveChannelID("reply"))
    static let status  = HiveChannelKey<Schema, Status>(HiveChannelID("status"))

    static func inputWrites(_ input: String, context: Void) -> [AnyHiveWrite<Schema>] {
        [AnyHiveWrite(key: message, value: input)]
    }

    static let channelSpecs: [AnyHiveChannelSpec<Schema>] = [
        AnyHiveChannelSpec(HiveChannelSpec(key: message, scope: .global,
            reducer: .lastWriteWins(), initial: { "" }, persistence: .untracked)),
        AnyHiveChannelSpec(HiveChannelSpec(key: reply, scope: .global,
            reducer: .lastWriteWins(), initial: { "" }, persistence: .untracked)),
        AnyHiveChannelSpec(HiveChannelSpec(key: status, scope: .global,
            reducer: .lastWriteWins(), initial: { .pending }, persistence: .untracked)),
    ]
}
```

> `@HiveSchema` macro (eliminates the `channelSpecs` boilerplate) is in progress.

---

## Patch and observe any graph at runtime

```swift
var patch = WorkflowPatch<Schema>()
patch.insertProbe("logger", between: "respond", and: "done") { input in
    print("reply:", input.store.get(Schema.reply))
    return Effects { End() }
}
let patched = try patch.apply(to: workflow.compile())
print(patched.diff.renderMermaid())   // Mermaid diagram with diff annotations
```

---

## Status

| Area | State |
|------|-------|
| Core runtime, superstep loop, BSP semantics | Stable |
| HiveDSL — Workflow / Node / Branch / Effects | Stable |
| ModelTurn + HiveModelToolLoop | Stable |
| Interrupt / resume | Stable |
| Checkpoint (in-memory + Wax WAL) | Stable |
| HiveConduit adapter | Stable |
| HIVE_V11_TRIGGERS reactive scheduling | Preview (`#if HIVE_V11_TRIGGERS`) |
| `@HiveSchema` / `@Channel` macros | In progress |
| Embedding-based recall (USearch wired) | Planned |

---

## Development

```sh
swift build
swift test
swift test --filter HiveCoreTests   # run a single target
swift run HiveTinyGraphExample
```

---

## License

MIT — see [LICENSE](../../LICENSE)
