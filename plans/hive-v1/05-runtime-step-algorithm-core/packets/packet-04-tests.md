Prompt:
You are a senior Swift 6.2 engineer. Implement the Plan 05 targeted tests using Swift Testing only. Do NOT edit any plan documents. Tests must be deterministic and focused on behavior.

Goal:
Add the §17.2 runtime determinism tests for routing, frontier ordering, join barriers, dedupe, and commit validation, ensuring failures do not mutate global state.

Task BreakDown
- Locate existing test helpers under `Tests/` or `libs/hive/Tests/` for graph/runtime fixtures and deterministic scheduling.
- Implement the following tests (or equivalent names) from §17.2:
  - `testRouterFreshRead_SeesOwnWriteNotOthers()`
  - `testRouterFreshRead_ErrorAbortsStep()`
  - `testRouterReturnUseGraphEdges_FallsBackToStaticEdges()`
  - `testGlobalWriteOrdering_DeterministicUnderRandomCompletion()`
  - `testDedupe_GraphSeedsOnly()`
  - `testFrontierOrdering_GraphBeforeSpawn()`
  - `testJoinBarrier_IncludesSpawnParents()`
  - `testJoinBarrier_TargetRunsEarly_DoesNotReset()`
  - `testJoinBarrier_ConsumeOnlyWhenAvailable()`
  - `testUnknownChannelWrite_FailsNoCommit()`
- Prefer small, composable fixtures for graphs, channels, and routers; avoid integration-only tests.
- Add any minimal test-only utilities to control task completion ordering to assert determinism.
- Ensure tests are self-contained, deterministic, and do not depend on checkpoint/resume behavior.
