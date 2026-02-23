---
sidebar_position: 2
title: ModelTurn & Subgraph
description: LLM integration with ModelTurn, agent loops, tool calling, and nested workflows via Subgraph.
---

# ModelTurn & Subgraph

## ModelTurn — LLM Integration

`ModelTurn` integrates LLM calls directly into the workflow graph:

```swift
ModelTurn("chat", model: "gpt-4", messages: [
    HiveChatMessage(id: "u1", role: .user, content: "Weather in SF?")
])
.tools(.environment)
.agentLoop(.init(maxModelInvocations: 8, toolCallOrder: .byNameThenID))
.writes(to: answerKey)
.writesMessages(to: historyKey)
.start()
```

### Tools Policy

| Policy | Behavior |
|--------|----------|
| `.none` | No tools available |
| `.environment` | Uses tools from `HiveEnvironment` |
| `.explicit([HiveToolDefinition])` | Specific tool list |

### Mode

| Mode | Behavior |
|------|----------|
| `.complete` | Single model call, return response |
| `.agentLoop(config)` | Multi-turn ReAct loop with tool calling |

### Agent Loop Configuration

The agent loop implements a bounded ReAct pattern:

1. Send conversation to model
2. If no tool calls, return final response
3. Execute tools, append results to conversation
4. Loop back (bounded by `maxModelInvocations`)

Configuration options:
- `modelCallMode`: `.complete` or `.stream`
- `maxModelInvocations`: safety limit
- `toolCallOrder`: `.asEmitted` or `.byNameThenID` (deterministic)

## Subgraph — Nested Workflows

Embed a child workflow within a parent graph:

```swift
Subgraph<ParentSchema, ChildSchema>(
    "sub",
    childGraph: childGraph,
    inputMapping: { parentStore in try parentStore.get(inputKey) },
    environmentMapping: { _ in childEnv },
    outputMapping: { _, childStore in
        [AnyHiveWrite(parentResultKey, try childStore.get(childResultKey))]
    }
)
```

Subgraphs run as a single node from the parent's perspective. The child graph executes independently with its own schema and store, then maps results back to the parent's channels.

## WorkflowBlueprint

Composable workflow fragments (SwiftUI-style protocol):

```swift
public protocol WorkflowBlueprint: WorkflowComponent {
    associatedtype Body: WorkflowComponent where Body.Schema == Schema
    @WorkflowBuilder<Schema> var body: Body { get }
}
```

Use blueprints to create reusable workflow components that can be composed into larger workflows.
