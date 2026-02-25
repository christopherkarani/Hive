---
sidebar_position: 3
title: Hybrid Inference
description: Model client protocol, ReAct loop, tool calling, and streaming.
---

# Hybrid Inference

## Model Client Protocol

```swift
public protocol HiveModelClient: Sendable {
    func complete(_ request: HiveChatRequest) async throws -> HiveChatResponse
    func stream(_ request: HiveChatRequest) -> AsyncThrowingStream<HiveChatStreamChunk, Error>
}
```

Streaming contract: the stream MUST emit exactly one `.final(HiveChatResponse)` as its last element.

## Inference Types

| Type | Purpose |
|------|---------|
| `HiveChatRole` | `.system`, `.user`, `.assistant`, `.tool` |
| `HiveChatMessage` | Chat message with tool calls |
| `HiveChatRequest` | Model request: model name, messages, tools |
| `HiveChatResponse` | Model response wrapping a message |
| `HiveChatStreamChunk` | `.token(String)` or `.final(HiveChatResponse)` |
| `HiveToolDefinition` | Tool exposed to models |
| `HiveToolCall` | Model-emitted tool invocation |
| `HiveToolResult` | Tool execution result |

## Model Tool Loop (ReAct)

`HiveModelToolLoop` implements a bounded ReAct loop:

1. Send conversation to model
2. If no tool calls, return final response
3. Execute tools, append results to conversation
4. Loop back (bounded by `maxModelInvocations`)

Configuration:
- `modelCallMode`: `.complete` or `.stream`
- `maxModelInvocations`: safety limit
- `toolCallOrder`: `.asEmitted` or `.byNameThenID` (deterministic)

```swift
ModelTurn("chat", model: "gpt-4", messages: [
    HiveChatMessage(id: "u1", role: .user, content: "Weather in SF?")
])
.tools(.environment)
.agentLoop(.init(maxModelInvocations: 8))
.writes(to: answerKey)
.start()
```

## Tool Registry

```swift
public protocol HiveToolRegistry: Sendable {
    func listTools() -> [HiveToolDefinition]
    func invoke(_ call: HiveToolCall) async throws -> HiveToolResult
}
```

## Model Router

Route between different model providers (on-device vs cloud) based on context:

```swift
public protocol HiveModelRouter: Sendable {
    func route(_ request: HiveChatRequest) -> AnyHiveModelClient
}
```

## Deterministic Token Streaming

When `deterministicTokenStreaming` is enabled in `HiveRunOptions`, the runtime buffers model tokens per-task and replays them in ordinal order. This ensures identical event traces even when multiple model calls run concurrently.
