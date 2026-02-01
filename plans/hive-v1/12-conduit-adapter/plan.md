# Plan 12 — Conduit adapter (`HiveConduit`)

## Goal

Implement the Conduit adapter layer:

- a `HiveModelClient` implementation backed by Conduit
- mapping Conduit streaming to Hive events (`modelInvocationStarted`, `modelToken`, `modelInvocationFinished`)
- any required Conduit→canonical type conversions
- ensure the `HiveChatStreamChunk` contract is preserved: exactly one terminal `.final(HiveChatResponse)` chunk on successful completion (§15.2)

## Spec anchors

- `HIVE_SPEC.md` §15.2 (Model client) and any Conduit-specific notes
- `HIVE_V1_PLAN.md` §11.2 (Conduit adapter boundary)

## Deliverables

- `libs/hive/Sources/HiveConduit/ConduitModelClient.swift` (or similar)
- Adapter tests using a stubbed Conduit client to simulate streaming and errors

## Work breakdown

1. Define the minimal Conduit-facing surface you need (avoid leaking Conduit types into `HiveCore`).
2. Implement streaming bridge:
   - preserve per-task stream ordering
   - enforce/guarantee the “final chunk” semantics required by §15.2 (and used by HiveAgents)
3. Emit Hive events via the runtime’s event hook API (from Plan 06).
4. Add tests with deterministic token streams:
   - stream is bracketed by start/finish events
   - successful streams include a final chunk and map into `modelInvocationFinished`

## Acceptance criteria

- Hive can run with a Conduit-backed model client and stream tokens through Hive events correctly.
