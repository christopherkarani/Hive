# Codex prompt — Plan 07 (Errors/retries/cancellation)

You are implementing **Plan 07** from `plans/hive-v1/07-errors-retries-cancellation-limits/plan.md`.

## Objective

Add `HiveRuntimeError`, retries, cancellation, and maxSteps behavior per `HIVE_SPEC.md` §11.

## Read first

- `HIVE_SPEC.md` §11.0–§11.4
- `HIVE_SPEC.md` §17.2 tests listed in the plan (including updatePolicy + reducer-throw atomicity cases)
- `HIVE_SPEC.md` §13.5 for how errors/cancellation terminate the events stream

## Constraints

- Retry backoff is deterministic (no jitter).
- Cancellation is not an error and must not terminate the event stream by throwing.
- `HiveClock.sleep(...)` throwing `CancellationError` during retry backoff must be treated as cancellation (per §11.2/§11.3).
- During-step cancellation requirements (per §11.3):
  - emit `taskFailed` for every frontier task in ascending `taskOrdinal` (as `CancellationError()`)
  - do not commit and do not emit commit-scoped events (`writeApplied`, `checkpointSaved`, `streamBackpressure`, `stepFinished`)
  - emit `runCancelled` as the terminal event

## Commands

- `cd libs/hive && swift test`
