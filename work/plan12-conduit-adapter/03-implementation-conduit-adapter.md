Prompt:
You are the Implementation Agent for Plan 12 (Conduit adapter). Implement the Conduit-backed model client and streaming bridge to Hive, adhering to the tests and spec.
Goal:
Deliver a `HiveModelClient` implementation backed by Conduit, with correct streaming, event emission, and Conduit-to-canonical type conversions.
Task Breakdown:
- Use the Task 01 context report and Task 02 tests as the authoritative guide.
- Implement `ConduitModelClient` (file per plan: `libs/hive/Sources/HiveConduit/ConduitModelClient.swift` or similar).
- Define the minimal Conduit-facing surface inside `HiveConduit` (avoid leaking Conduit types into `HiveCore`).
- Bridge Conduit streaming to `HiveChatStreamChunk` while preserving per-task ordering.
- Enforce exactly one terminal `.final(HiveChatResponse)` chunk on successful completion.
- Emit runtime events via the event hook API (from Plan 06) for start/token/finish.
- Add any required Conduit→canonical type conversions (messages, usage, metadata).
- Keep visibility minimal and types safe; avoid `Any` or type erasure unless required.
Expected Output:
- Implementation code that satisfies all tests and meets §15.2 final-chunk semantics.
