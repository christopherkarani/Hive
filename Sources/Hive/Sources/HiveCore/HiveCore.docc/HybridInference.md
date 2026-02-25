# Hybrid Inference

Integrate LLM providers with the model client protocol, ReAct loops, and tool registries.

## Overview

Hive's hybrid inference system provides a protocol-based abstraction over LLM providers. The ``HiveModelClient`` protocol defines streaming and completion interfaces, while ``HiveModelToolLoop`` implements a bounded ReAct loop for multi-turn tool calling.

## Model client protocol

```swift
public protocol HiveModelClient: Sendable {
    func complete(
        _ request: HiveChatRequest
    ) async throws -> HiveChatResponse

    func stream(
        _ request: HiveChatRequest
    ) -> AsyncThrowingStream<HiveChatStreamChunk, Error>
}
```

The streaming contract requires that the stream emits exactly one `.final(HiveChatResponse)` as its last element.

## Inference types

| Type | Purpose |
|------|---------|
| ``HiveChatRole`` | `.system`, `.user`, `.assistant`, `.tool` |
| ``HiveChatMessage`` | Chat message with optional tool calls |
| ``HiveChatRequest`` | Model request: model name, messages, tools |
| ``HiveChatResponse`` | Model response wrapping a message |
| ``HiveChatStreamChunk`` | `.token(String)` or `.final(HiveChatResponse)` |
| ``HiveToolDefinition`` | Tool schema exposed to models |
| ``HiveToolCall`` | Model-emitted tool invocation |
| ``HiveToolResult`` | Tool execution result |

## Model tool loop (ReAct)

``HiveModelToolLoop`` implements a bounded ReAct loop:

1. Send conversation to model
2. If no tool calls, return the final response
3. Execute tools, append results to conversation
4. Loop back (bounded by `maxModelInvocations`)

Configuration options:

- `modelCallMode` — `.complete` or `.stream`
- `maxModelInvocations` — safety limit for loop iterations
- `toolCallOrder` — `.asEmitted` or `.byNameThenID` (deterministic)

## Tool registry

Implement ``HiveToolRegistry`` to expose tools to models:

```swift
public protocol HiveToolRegistry: Sendable {
    func listTools() -> [HiveToolDefinition]
    func invoke(
        _ call: HiveToolCall
    ) async throws -> HiveToolResult
}
```

The tool registry is provided via ``HiveEnvironment`` and accessed by `ModelTurn` nodes in the DSL.

## Using with the DSL

The `ModelTurn` DSL component integrates inference into workflows:

```swift
ModelTurn("chat", model: "gpt-4", messages: [
    HiveChatMessage(
        id: "u1", role: .user, content: "Weather in SF?"
    )
])
.tools(.environment)
.agentLoop(.init(maxModelInvocations: 8))
.writes(to: answerKey)
.start()
```

Tools policy options:

- `.none` — no tools
- `.environment` — use tools from ``HiveEnvironment``
- `.explicit([HiveToolDefinition])` — inline tool definitions
