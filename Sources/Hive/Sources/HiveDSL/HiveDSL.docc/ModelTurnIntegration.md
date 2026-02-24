# ModelTurn Integration

Add LLM-powered nodes to workflows with tool calling, agent loops, and streaming.

## Overview

``ModelTurn`` is a DSL component that creates nodes powered by LLM inference. It handles message construction, tool calling, agent loops, and writing results back to the store — all within Hive's deterministic execution model.

## Basic usage

```swift
ModelTurn("chat", model: "gpt-4", messages: [
    HiveChatMessage(
        id: "u1", role: .user, content: "Weather in SF?"
    )
])
.writes(to: answerKey)
.start()
```

This creates a node that sends the messages to the model, captures the response, and writes it to `answerKey`.

## Tool calling

### Environment tools

Use tools registered in the `HiveEnvironment`:

```swift
ModelTurn("agent", model: "gpt-4", messages: messages)
    .tools(.environment)
    .writes(to: responseKey)
    .start()
```

### No tools

Disable tool calling:

```swift
.tools(.none)
```

### Explicit tools

Provide tool definitions inline:

```swift
.tools(.explicit([weatherTool, searchTool]))
```

## Agent loops

Enable a bounded ReAct loop for multi-turn tool calling:

```swift
ModelTurn("agent", model: "gpt-4", messages: messages)
    .tools(.environment)
    .agentLoop(.init(
        maxModelInvocations: 8,
        toolCallOrder: .byNameThenID
    ))
    .writes(to: answerKey)
    .writesMessages(to: historyKey)
    .start()
```

The agent loop:

1. Sends the conversation to the model
2. If the model returns tool calls, executes them
3. Appends tool results to the conversation
4. Loops back to the model (bounded by `maxModelInvocations`)
5. Returns the final response when no more tool calls are needed

### Tool call ordering

- `.asEmitted` — process tool calls in the order the model emits them
- `.byNameThenID` — sort by name then ID for deterministic execution

## Writing results

### Response text

Write the model's response text to a channel:

```swift
.writes(to: answerKey)
```

### Message history

Write the full conversation history (including tool calls and results) to a channel:

```swift
.writesMessages(to: historyKey)
```

## Mode selection

ModelTurn supports two modes:

- **Complete** (default) — single model call, returns the response
- **Agent loop** — multi-turn ReAct loop with tool calling

```swift
// Single call (default)
ModelTurn("chat", model: "gpt-4", messages: messages)
    .writes(to: key)

// Agent loop
ModelTurn("agent", model: "gpt-4", messages: messages)
    .agentLoop(.init(maxModelInvocations: 8))
    .tools(.environment)
    .writes(to: key)
```

## Complete example

```swift
let workflow = Workflow<Schema> {
    Node("prepare") { input in
        let query = try input.store.get(Schema.queryKey)
        return Effects {
            Set(Schema.messagesKey, [
                HiveChatMessage(
                    id: "sys", role: .system,
                    content: "You are a helpful assistant."
                ),
                HiveChatMessage(
                    id: "user", role: .user,
                    content: query
                )
            ])
            GoTo("chat")
        }
    }.start()

    ModelTurn("chat", model: "gpt-4", messages: [])
        .tools(.environment)
        .agentLoop(.init(maxModelInvocations: 5))
        .writes(to: Schema.answerKey)
        .writesMessages(to: Schema.historyKey)

    Edge("chat", to: "done")
    Node("done") { _ in Effects { End() } }
}
```
