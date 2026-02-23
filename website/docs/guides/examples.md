---
sidebar_position: 4
title: Examples
description: Hello World, branching, agent loops, fan-out/join/interrupt, and TinyGraph walkthrough.
---

# Examples

## Hello World

The simplest possible Hive workflow:

```swift
let messageKey = HiveChannelKey<Schema, String>(HiveChannelID("message"))

let graph = try Workflow<Schema> {
    Node("greet") { _ in
        Effects {
            Set(messageKey, "Hello from Hive!")
            End()
        }
    }.start()
}.compile()
```

## Branching

Conditional routing based on computed state:

```swift
let graph = try Workflow<Schema> {
    Node("check") { _ in
        Effects { Set(scoreKey, 85); UseGraphEdges() }
    }.start()

    Node("pass") { _ in Effects { Set(resultKey, "passed"); End() } }
    Node("fail") { _ in Effects { Set(resultKey, "failed"); End() } }

    Branch(from: "check") {
        Branch.case(name: "high", when: { ($0.get(scoreKey) ?? 0) >= 70 }) {
            GoTo("pass")
        }
        Branch.default { GoTo("fail") }
    }
}.compile()
```

## Agent Loop with LLM

A 5-line agent loop with tool calling:

```swift
let graph = try Workflow<Schema> {
    ModelTurn("chat", model: "claude-sonnet-4-5-20250929", messages: [
        HiveChatMessage(id: "u1", role: .user, content: "Weather in SF?")
    ])
    .tools(.environment)
    .agentLoop(.init(maxModelInvocations: 8))
    .writes(to: answerKey)
    .start()
}.compile()
```

## Fan-Out, Join, Interrupt

Parallel workers with barrier sync and human approval:

```swift
let graph = try Workflow<Schema> {
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
        return Effects { Append(resultsKey, elements: [item.uppercased()]); End() }
    }

    Node("review") { _ in Effects { Interrupt("Approve results?") } }
    Node("done") { _ in Effects { End() } }

    Join(parents: ["worker"], to: "review")
    Edge("review", to: "done")
}.compile()

// Run → interrupt → resume
let handle = await runtime.run(threadID: tid, input: (), options: opts)
let outcome = try await handle.outcome.value
guard case let .interrupted(interruption) = outcome else { return }

let resumed = await runtime.resume(
    threadID: tid,
    interruptID: interruption.interrupt.id,
    payload: "approved",
    options: opts
)
```

## TinyGraph Example

The executable at `Sources/Hive/Examples/TinyGraph/main.swift` demonstrates a complete workflow:

- Schema with custom codecs (`StringCodec`, `StringArrayCodec`)
- Fan-out via `spawn` with task-local state
- Join barrier waiting for parallel workers
- Interrupt/resume with typed payloads
- In-memory checkpoint store

Run it directly:

```bash
swift run HiveTinyGraphExample
```

No API keys required. The example runs fan-out workers, a join barrier, and an interrupt/resume cycle entirely in-process.
