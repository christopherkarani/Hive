# Public API Map (What to Import, When)

## Imports
- One-stop: `import Hive` (re-exports `HiveCore`, `HiveDSL`, `HiveConduit`, `HiveCheckpointWax`)
- Minimal core: `import HiveCore`
- DSL-only: `import HiveDSL` (re-exports `HiveCore`)
- Inference adapter: `import HiveConduit` (re-exports `HiveCore`)
- Checkpoint adapter: `import HiveCheckpointWax` (re-exports `HiveCore`)
- RAG primitives: `import HiveRAGWax` (re-exports `HiveDSL`)
- Macros: `import HiveMacros` (optional compiler plugin)

## HiveCore (Core Runtime)
- Schema + channels:
  - `HiveSchema`
  - `HiveChannelID`, `HiveChannelKey`, `HiveChannelSpec`, `AnyHiveChannelSpec`
  - `HiveReducer` (+ standard reducers)
  - `HiveCodec`, `HiveAnyCodec`, `HiveJSONCodec`
- Graph compilation:
  - `HiveGraphBuilder`
  - `HiveNodeID`, `HiveNext`, `HiveRouter`
  - `HiveJoinEdge`, `HiveOutputProjection`, `CompiledHiveGraph`
- Runtime execution:
  - `HiveRuntime` (actor)
  - `HiveRunOptions`, `HiveCheckpointPolicy`
  - `HiveRunHandle`, `HiveRunOutcome`, `HiveRunOutput`
  - Events: `HiveEvent`, `HiveEventKind`, `HiveEventID`
- Interrupt/resume:
  - `HiveInterruptRequest`, `HiveInterrupt`, `HiveResume`, `HiveInterruption`, `HiveInterruptID`
- Environment:
  - `HiveEnvironment`, `HiveClock`, `HiveLogger`
- Hybrid inference contracts (adapter interfaces, not implementations):
  - `HiveModelClient`, `AnyHiveModelClient`
  - `HiveToolRegistry`, `AnyHiveToolRegistry`
  - `HiveModelRouter`, `HiveInferenceHints`
  - Chat types: `HiveChatMessage`, `HiveChatRequest`, `HiveChatResponse`, `HiveToolDefinition`, `HiveToolCall`, `HiveToolResult`

## HiveDSL (Workflow Composition)
- Workflow assembly:
  - `Workflow`, `WorkflowBundle`, `WorkflowComponent`, `AnyWorkflowComponent`
- Graph pieces:
  - `Node`, `Edge`, `Join`, `Chain`, `Branch`
- Effects:
  - `Effects { ... }`, `Set`, `Append`, `GoTo`, `UseGraphEdges`, `End`, `Interrupt`, `SpawnEach`
- Model turn:
  - `ModelTurn` with `.tools(...)` and `.writes(to: ...)`
- Patching/diff:
  - `WorkflowPatch`, `WorkflowDiff` (Mermaid rendering)

## HiveConduit (Model Adapter)
- `ConduitModelClient`: implements `HiveModelClient` using Conduit `TextGenerator`.
- Key contract: streaming MUST end with exactly one final response.

## HiveCheckpointWax (Checkpoint Store)
- `HiveCheckpointWaxStore`: implements checkpoint persistence via Wax frames.

## HiveRAGWax (RAG Primitives)
- `WaxRecall`: DSL component; runs recall and writes `[HiveRAGSnippet]` to a channel.
- `HiveRAGSnippet`: checkpoint-friendly snippet format.

## HiveMacros (Optional)
- `@HiveSchema`, `@Channel`, `@TaskLocalChannel`, `@WorkflowBlueprint`

