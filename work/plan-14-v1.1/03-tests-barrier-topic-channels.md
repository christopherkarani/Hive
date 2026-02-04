Prompt:
Add failing Swift Testing tests for v1.1 generalized barrier/topic channels (state value types + deterministic reducers + helpers), per `plans/plan-14-v1.1-implementation.md`.

Goal:
Define the behavioral contract (TDD) for:
- barrier state accumulation via `markSeen`
- deterministic consume semantics
- topic publish/clear semantics under multi-writer updates
- determinism under stable ordering

Task Breakdown:
1) Add a new test file under `libs/hive/Tests/HiveCoreTests/Schema/`:
   - Construct barrier/topic channel value updates and reduce them using the provided reducers.
   - Verify reducer normalization (stored value is state, not update payload).
   - Verify determinism across permutations where ordering is defined by Hive’s deterministic write ordering model.
2) Add an integration-style runtime test only if needed:
   - Define a tiny schema using barrier/topic channel values with a stable codec.
   - Run a small graph, checkpoint, resume, and verify state parity.

Expected Output:
- New failing tests:
  - `libs/hive/Tests/HiveCoreTests/Schema/HiveBarrierTopicChannelsTests.swift`

