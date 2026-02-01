Prompt:
You are a senior Swift 6.2 engineer. Implement the deterministic superstep core for Plan 05. Do NOT edit any plan documents. Keep the algorithm correct, readable, and deterministically ordered.

Goal:
Build the core step algorithm: task execution, deterministic commit, router fresh-reads, frontier computation, and join barrier rules, sufficient to satisfy §17.2 tests.

Task BreakDown
- Locate or create the runtime step engine module under `libs/hive/Sources/HiveCore/Runtime/`.
- Implement per-thread in-memory run state (§10.0): runID, stepIndex, global snapshot, frontier, join progress, interruption placeholder, latestCheckpointID.
- Step algorithm core:
  - Seed frontier from `graph.start` in order when empty.
  - Apply `Schema.inputWrites` as synthetic writes before step 0.
  - Execute tasks concurrently but buffer outputs deterministically by `taskOrdinal`.
  - Deterministic commit order for writes; compute per-task fresh-read views (preStepGlobal + thisTaskWrites).
  - Router evaluation after commit-time validations succeed; router-view errors fail the step at commit time.
  - Next frontier ordering: graph seeds before spawn seeds.
  - Stop when next frontier is empty (maxSteps/out-of-steps deferred to Plan 07).
- Implement join barrier consume/contribute rules per §9.1 and §10.4.
- Enforce “no commit on validation failure” for unknown channel writes (and placeholders for other validations).
- Add internal comments only where clarity demands; avoid over-abstraction.
