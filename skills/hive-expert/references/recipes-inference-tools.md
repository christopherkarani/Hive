# Recipe: Inference + Tools

## Goal
Run a model turn (chat completion) inside Hive with deterministic streaming + tool calling.

## Core Interfaces (HiveCore)
- `HiveModelClient`:
  - `complete(_:) async throws -> HiveChatResponse`
  - `stream(_:) -> AsyncThrowingStream<HiveChatStreamChunk, Error>`
  - Streaming contract: exactly one `.final(...)`, last.
- `HiveToolRegistry`:
  - `listTools() -> [HiveToolDefinition]`
  - `invoke(_:) async throws -> HiveToolResult`
- `HiveEnvironment` carries:
  - `model: AnyHiveModelClient?`
  - `modelRouter: any HiveModelRouter?` (route based on `HiveInferenceHints`)
  - `tools: AnyHiveToolRegistry?`

## Using HiveDSL `ModelTurn`
1. Create `ModelTurn("LLM", model: "name") { store in ... }` to generate messages from store state.
1. Choose tool policy:
   - `.tools(.none)` (default)
   - `.tools(.environment)` to expose `environment.tools`
   - `.tools(.explicit([...]))`
1. Project output to a channel:
   - `.writes(to: Schema.Channels.answer)`

## Using HiveConduit
If you’re using Conduit:
- Wrap your Conduit provider with `ConduitModelClient`, then `AnyHiveModelClient(...)`.
- Ensure Conduit streaming produces a final completion chunk; otherwise Hive will throw `modelStreamInvalid`.

## Common Failure Modes
- Tool schemas invalid:
  - `HiveToolDefinition.parametersJSONSchema` must be valid JSON schema string; adapters may require object schemas.
- Stream invalid:
  - Missing `.final`, multiple finals, token after final.
- Missing model:
  - `environment.model` nil and no router → model turns fail.

