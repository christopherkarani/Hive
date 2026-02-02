# Plan 11 — SwiftAgents-on-Hive prebuilt graph + facade

## Goal

Implement the SwiftAgents-on-Hive “batteries included” prebuilt agent graph (in the SwiftAgents repo):

- Public facade types and schema
- Messages reducer and update semantics (append/replace-by-id/remove/remove-all)
- Prebuilt nodes and graph wiring
- Tool approval interrupt/resume flow
- Context compaction behavior (without mutating canonical `messages`)

## Spec anchors

- `HIVE_SPEC.md` §16.1–§16.6 (all)
- `HIVE_SPEC.md` §13 (events) where nodes emit model/tool events
- Required tests in §17.2 under “HiveAgents”, including:
  - `testAgentsMessagesReducer_RemoveAll_UsesLastMarker()`
  - `testAgentsCompaction_TrimsToBudget_WithoutMutatingMessages()`
  - `testAgentsModelStream_MissingFinalFails()`
  - `testAgentsToolApproval_InterruptsAndResumes()`
  - `testAgentsToolExecute_AppendsToolMessageWithDeterministicID()`

## Deliverables

- SwiftAgents repo: `Sources/HiveSwiftAgents/` (module name preserved) implementing:
  - the public facade API (all types in §16.1), including:
    - `HiveAgentsToolApprovalPolicy`
    - `HiveAgents` (+ nested `ToolApprovalDecision`, `Interrupt`, `Resume`, `removeAllMessagesID`, `makeToolUsingChatAgent(...)`)
    - `HiveTokenizer`
    - `HiveCompactionPolicy`
    - `HiveAgentsContext`
    - `HiveAgentsRuntime`
  - schema definition in §16.2
  - messages reducer in §16.3
  - node set + wiring + facade behavior in §16.4–§16.6
- SwiftAgents adapter surface for Hive integration (per `HIVE_V1_PLAN.md` intent), e.g. a `SwiftAgentsToolRegistry` bridging SwiftAgents tools into `HiveToolRegistry`.
- `HiveCore` hooks required by these nodes:
  - model/tool event emission (Plan 06)
  - interrupt/resume APIs (Plan 08/09)
  - tool registry + model client (Plan 10)
- Swift Testing coverage for the required tests above.

## Work breakdown

1. Implement `HiveAgents` public API types and schema channels.
   - Enforce §16.1 environment preflight rules (“fail before step 0”):
     - require `HiveEnvironment.modelRouter != nil || model != nil` else `HiveRuntimeError.modelClientMissing`
     - require `HiveEnvironment.tools != nil` else `HiveRuntimeError.toolRegistryMissing`
     - if `compactionPolicy != nil`: require tokenizer and validate `maxTokens >= 1`, `preserveLastMessages >= 0` else `HiveRuntimeError.invalidRunOptions`
     - document that `HiveAgentsRuntime` defaults `checkpointPolicy = .everyStep` so a checkpoint store is required unless overridden
2. Implement messages reducer with exact semantics and deterministic duplicate-ID handling.
   - Include deterministic user message ID generation in `Schema.inputWrites` per §16.2.
3. Implement prebuilt nodes:
   - model invocation node with streaming handling and missing-final failure behavior
   - tool selection/execution nodes
   - compaction node producing `llmInputMessages` without mutating `messages`
4. Wire the compiled graph per spec.
5. Implement tool approval flow:
   - interrupt payload lists sorted tool calls
   - resume applies approval decision deterministically
6. Add tests.
   - Add focused “fail before step 0” preflight tests for the environment requirements (even if not enumerated in §17.2).

## Acceptance criteria

- Prebuilt graph runs end-to-end for tool approval workflows and compaction, with deterministic traces.
- No Hive package targets are added or modified for SwiftAgents-on-Hive (implementation lives in SwiftAgents).
