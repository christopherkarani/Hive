Prompt:
You are a Swift 6.2 engineer implementing Plan 07 runtime semantics in `libs/hive/Sources/HiveCore/Runtime/`. You MUST NOT edit `plans/hive-v1/07-errors-retries-cancellation-limits/plan.md` (or any plan document). Implement the simplest correct behavior first; keep APIs Swifty, strongly typed, and deterministic.

Goal:
Update the runtime to match `HIVE_SPEC.md` for:
- `maxSteps` / out-of-steps stopping (before emitting `stepStarted`)
- cancellation semantics (between steps; during a step, including event rules)
- retry attempt loop with deterministic exponential backoff using injected `HiveClock` (no jitter), discarding failed-attempt outputs, and validation-before-step0
- deterministic error selection when multiple task failures occur (§11.4), and commit-time failure precedence order (§10.4)

Task BreakDown:
1. Locate current runtime control flow:
   - Read `libs/hive/Sources/HiveCore/Runtime/HiveRuntime.swift`
   - Identify where step loop, event emission (`HiveEventStreamController`), and commit-phase validation happen.
   - Identify how node retry policy is represented in compiled graph (search for `retryPolicy:` in graph compilation).

2. Implement `maxSteps` stop condition exactly as specified:
   - Track `stepsExecutedThisAttempt` (0 at attempt start; increment only after a successfully committed step).
   - Before emitting `stepStarted` for the next step:
     - If `stepsExecutedThisAttempt == options.maxSteps`:
       - If frontier empty: finish normally.
       - Else: stop immediately and return outcome `.outOfSteps(maxSteps: options.maxSteps, ...)`.
   - Ensure `applyExternalWrites(...)` continues to ignore `maxSteps` (one synthetic committed step).

3. Implement retry attempt loop + determinism:
   - Retry policy validation (before step 0):
     - For `.exponentialBackoff`, validate `maxAttempts >= 1`, `factor.isFinite`, `factor >= 1.0`.
     - If multiple nodes invalid, throw `HiveRuntimeError.invalidRunOptions(...)` for smallest `HiveNodeID.rawValue` (lexicographic).
   - Attempt loop for each node execution:
     - Discard outputs from failed attempts (writes/spawn/next/interrupt/stream buffers).
     - If backoff sleep needed, compute delay per §11.2 (UInt64 floor + clamp) and call `environment.clock.sleep(nanoseconds:)`.
     - If `clock.sleep` throws `CancellationError`, treat as cancellation (NOT an error): apply §11.3 cancellation behavior.
     - If `clock.sleep` throws any other error: fail step by throwing that error; do not commit.

4. Implement cancellation semantics (runtime-observed cancellation is not an error):
   - Between steps:
     - If `Task.isCancelled` is observed before emitting `stepStarted` for the next step, stop immediately.
     - Emit `.runCancelled` as the terminal event; complete outcome as `.cancelled(output: latestCommittedProjection, checkpointID: latestCheckpointID)`.
   - During a step (after `stepStarted`, before commit):
     - Cancel all in-flight node tasks for that step.
     - Emit `.taskFailed` for EVERY frontier task in ascending `taskOrdinal`, using `CancellationError()` as the conceptual failure.
     - Do NOT commit (no writes/barriers/frontier/checkpoint for that step).
     - Do NOT emit commit-scoped events: `.writeApplied`, `.checkpointSaved`, `.streamBackpressure`, `.stepFinished`.
     - Emit `.runCancelled` as the terminal event.
   - Streaming interaction:
     - If `deterministicTokenStreaming == true`, discard buffered stream events for a cancelled step.
     - If `deterministicTokenStreaming == false`, already-emitted stream events remain, but NOTHING may be emitted after `.runCancelled`.

5. Deterministic failure selection when multiple failures occur:
   - If a step fails because tasks fail after retries: throw the FINAL error (post-retries) from the smallest failing `taskOrdinal` (§11.4).
   - If a step fails due to commit-time validation: throw the first failure in §10.4 precedence order (unknownChannelID beats updatePolicy violation, etc.).
   - Ensure step atomicity: any failure prevents commit (and prevents commit-scoped events).

6. Output expectations (in your response):
   - List exact files touched (paths) and describe the change per file.
   - Call out any behavior that required refactoring (e.g., separating compute vs commit, or centralizing cancellation checks).
   - Confirm how determinism is achieved (ordering keys, buffering boundaries).

