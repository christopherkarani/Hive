Prompt:
You are a Swift 6.2 engineer working in `libs/hive` using the Swift Testing framework (`import Testing`). Your job is to add (or update) tests for Plan 07: errors, retries, cancellation, and maxSteps semantics. You MUST NOT edit `plans/hive-v1/07-errors-retries-cancellation-limits/plan.md` (or any plan document). Prefer new focused test files over adding more to already-large ones unless there is a clear reason.

Goal:
Add deterministic, behavior-focused tests that pin the v1 semantics in `HIVE_SPEC.md`:
- Required §17.2 tests (listed in Plan 07).
- Additional tests for retry policy validation + deterministic exponential backoff (no jitter), cancellation (between steps + during step), and `maxSteps` out-of-steps behavior.

Task BreakDown:
1. Read spec anchors (do not reinterpret):
   - `HIVE_SPEC.md` §10.4 “Commit-time validation order and failure precedence”
   - `HIVE_SPEC.md` §11.1–§11.4 (atomicity, retry determinism, cancellation, error selection)
   - `HIVE_SPEC.md` “Stop conditions and maxSteps” (just above §11)

2. Add the REQUIRED tests from Plan 07 (name them exactly as specified):
   - `testMultipleTaskFailures_ThrowsEarliestOrdinalError()`
   - `testCommitFailurePrecedence_UnknownChannelBeatsUpdatePolicy()`
   - `testUpdatePolicySingle_GlobalViolatesAcrossTasks_FailsNoCommit()`
   - `testUpdatePolicySingle_TaskLocalPerTask_AllowsAcrossTasks()`
   - `testReducerThrows_AbortsStep_NoCommit()`
   - `testOutOfSteps_StopsWithoutExecutingAnotherStep()`
   Notes:
   - Put these in a new test file under `libs/hive/Tests/HiveCoreTests/Runtime/` (suggestion: `HiveRuntimeErrorsRetriesCancellationTests.swift`) unless you find a more appropriate existing file.
   - Ensure each test asserts both outcome/error AND event sequencing invariants (no commit-scoped events on failure; deterministic ordering where required).

3. Add retry policy determinism tests (minimum set to lock behavior):
   - Validation-before-step0: when multiple nodes have invalid retry policy parameters, assert the run fails before step 0 with `HiveRuntimeError.invalidRunOptions(...)` for the lexicographically-smallest `HiveNodeID.rawValue`.
   - Backoff schedule: inject a `HiveClock` test double (recording `sleep(nanoseconds:)` calls) and assert:
     - sleeps match §11.2 formula (`floor(initial * pow(factor, attempt-1))`, clamped to `maxNanoseconds`)
     - no jitter (exact values)
     - sleep is called between failed attempts only
   - Exhaustion: assert that when retries are exhausted the thrown error is from the smallest `taskOrdinal` among failed tasks (§11.4), and that failed-attempt writes are discarded (no `writeApplied`).

4. Add cancellation tests (must be deterministic and assert events precisely):
   - Between steps cancellation:
     - Arrange a run that commits step 0, then blocks before step 1 starts.
     - Cancel the run and assert NO `stepStarted` for step 1 is emitted; terminal event is `.runCancelled`; outcome is `.cancelled(...)`.
   - During-step cancellation:
     - Arrange at least 2 frontier tasks that can be kept in-flight (e.g., `Task.sleep` inside node body).
     - Observe `stepStarted` for step S, then cancel.
     - Assert:
       - runtime emits `taskFailed` for EVERY frontier task in ascending `taskOrdinal`, with `errorDescription` matching cancellation
       - NO commit-scoped events for step S: `.writeApplied`, `.checkpointSaved`, `.streamBackpressure`, `.stepFinished`
       - terminal event is `.runCancelled`
     - If `deterministicTokenStreaming == true`, also assert stream events for the cancelled step are not emitted (discarded).

5. Make tests robust and fast:
   - Avoid real sleeps where possible; prefer controlled clocks / explicit async gates.
   - Avoid timing flakes: use `AsyncStream`/`AsyncThrowingStream` collection helpers and deterministic synchronization.
   - Keep schemas minimal; inline small `HiveSchema` enums inside tests.

6. Output expectations (in your response):
   - List all files created/modified (paths).
   - For each test, include a 1–2 sentence “behavior pinned” note.
   - Call out any spec ambiguity you encountered (with exact section references) instead of guessing.

