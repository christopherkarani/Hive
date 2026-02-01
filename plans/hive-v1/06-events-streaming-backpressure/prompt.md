# Codex prompt — Plan 06 (Events + streaming)

You are implementing **Plan 06** from `plans/hive-v1/06-events-streaming-backpressure/plan.md`.

## Objective

Implement `HiveEvent` streaming semantics and backpressure per `HIVE_SPEC.md` §13, updating the runtime to emit events in the required deterministic order.

## Read first

- `HIVE_SPEC.md` §13.1–§13.5
- `HIVE_SPEC.md` §17.2 tests listed in the plan

## Constraints

- Deterministic events must not depend on concurrency timing.
- Buffer overflow behavior must be deterministic and match the spec (coalesce/drop only for droppable kinds).
- Implement §13.3 hashing/redaction precisely:
  - `writeApplied.payloadHash` uses the canonical hashing rules
  - `debugPayloads` gates inclusion of payload bytes/strings in metadata
  - `taskFailed.errorDescription` redaction matches `debugPayloads`
- Implement the §13.4 per-task bound in `deterministicTokenStreaming == true` mode:
  - droppable stream events (`modelToken`, `customDebug`) can coalesce/drop within the per-task buffer
  - non-droppable stream events that would exceed the per-task bound must fail the step with `HiveRuntimeError.modelStreamInvalid(...)`
- Implement §13.5 termination precisely:
  - for errors, `HiveRunHandle.outcome` and `HiveRunHandle.events` must fail with the same error
  - cancellation is not an error and must end the events stream normally after `runCancelled`
- Support §13.2 retry interactions for stream events (Plan 07 will wire retries, but the event model must be able to represent it):
  - `taskStarted`/`taskFinished`/`taskFailed` are per task, not per retry attempt
  - in `deterministicTokenStreaming == true`, discard failed-attempt buffered stream events

## Commands

- `cd libs/hive && swift test`
