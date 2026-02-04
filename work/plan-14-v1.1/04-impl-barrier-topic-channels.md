Prompt:
Implement v1.1 barrier/topic channel value types + reducers + helpers in HiveCore, making all tests from task 03 pass.

Goal:
Provide Swift-typed, deterministic building blocks for “barriers as channels” and “topics as channels” without altering runtime scheduling semantics.

Task Breakdown:
1) Barrier types:
   - `HiveBarrierKey`, `HiveBarrierToken` (Sendable, Hashable, Codable)
   - `HiveBarrierUpdate` (`markSeen`, `consume`)
   - `HiveBarrierState` (deterministic representation; avoid non-deterministic `Set` encoding in canonical bytes)
   - `HiveBarrierChannelValue` (state+update wrapper) OR an equivalent misuse-resistant design that works with `HiveReducer<Value>`
   - `HiveReducer` constructor/helper for barriers
   - Helper utilities: `isAvailable(...)`, `consumingIfAvailable(...)`
2) Topic types:
   - `HiveTopicKey`
   - `HiveTopicUpdate<Value>`
   - `HiveTopicState<Value>` with explicit bounded policy (deterministic eviction)
   - `HiveTopicChannelValue<Value>` (state+update wrapper)
   - `HiveReducer` helper for topics
3) Codec ergonomics (optional but preferred):
   - Add a stable JSON codec helper for `Codable & Sendable` values to reduce footguns when checkpointing these channel values.
4) Ensure all tests from task 03 pass.

Expected Output:
- New/updated HiveCore sources under `libs/hive/Sources/HiveCore/` (likely `Schema/`):
  - Barrier/topic types and reducers
  - Optional stable JSON codec helper

