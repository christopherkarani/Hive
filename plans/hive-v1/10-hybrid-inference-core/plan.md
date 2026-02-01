# Plan 10 — Hybrid inference core types, model client, tool registry

## Goal

Implement the canonical inference surface in `HiveCore`:

- canonical chat/tool/message representations
- `HiveModelClient` contract (including streaming expectations)
- tool registry contract
- hybrid inference hints and routing metadata types

This plan defines the “portable” types used by `HiveConduit` and `HiveSwiftAgents`.

## Spec anchors

- `HIVE_SPEC.md` §15.1–§15.4
- Required tests in §17.2 that reference this area:
  - `testAgentsModelStream_MissingFinalFails()` (behavior enforced in HiveSwiftAgents nodes, but depends on the model client contract)

## Deliverables

- `libs/hive/Sources/HiveCore/HybridInference/`:
  - Canonical chat/tool types per §15.1:
    - `HiveChatRole`, `HiveToolDefinition`, `HiveToolCall`, `HiveToolResult`, `HiveChatMessageOp`, `HiveChatMessage`
  - Model client surface per §15.2:
    - `HiveChatRequest`, `HiveChatResponse`, `HiveChatStreamChunk`, `HiveModelClient`, `AnyHiveModelClient`
  - Tool registry surface per §15.3:
    - `HiveToolRegistry`, `AnyHiveToolRegistry`
  - Hybrid routing/hints per §15.4:
    - `HiveModelRouter`, `HiveLatencyTier`, `HiveNetworkState`, `HiveInferenceHints`
- Focused unit tests for Codable stability and basic invariants (no provider adapter yet).

## Work breakdown

1. Implement canonical types as per the spec (keep them minimal and Codable).
2. Define model client streaming contract with clear invariants needed by HiveAgents:
   - “final chunk” requirement and how missing-final is detected (plumb the error type, enforcement can be in Plan 11).
   - `complete(_:)` must equal the `.final(...)` response for the same request (per §15.2).
3. Define tool registry API and the minimum invocation metadata needed for tool approval flows.
4. Add small tests for encoding/decoding and deterministic IDs where spec requires.

## Acceptance criteria

- `HiveCore` exposes canonical, provider-agnostic types usable by adapters.
- No dependency on Conduit/SwiftAgents/Wax in `HiveCore`.
