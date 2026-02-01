# Plan 06 — Events, streaming, debug payloads, backpressure

## Goal

Implement the event stream model in `HiveCore`:

- `HiveEventID`, `HiveEvent`, `HiveEventKind`
- deterministic vs stream event delivery modes
- per-run event buffering capacity + deterministic backpressure behavior
- debug payload inclusion rules (`debugPayloads`)
- event stream termination semantics (errors vs cancellation vs outcomes)

## Spec anchors

- `HIVE_SPEC.md` §13.1–§13.5 (all)
- Related runtime requirements in §10.4 (where events are emitted)
- Required tests in §17.2:
  - `testEventSequence_DeterministicEventsOrder()`
  - `testFailedStep_NoStepFinishedOrWriteApplied()`
  - `testDebugPayloads_WriteAppliedMetadata()`
  - `testDeterministicTokenStreaming_BuffersStreamEvents()`
  - `testBackpressure_ModelTokensCoalesceAndDropDeterministically()`

## Deliverables

- `libs/hive/Sources/HiveCore/Runtime/HiveEvent.swift` (and related types)
- Event buffer implementation (bounded, deterministic overflow policy)
- Runtime wiring so:
  - deterministic events are emitted in the canonical order independent of concurrency timing
  - stream events are live by default
  - deterministicTokenStreaming buffers stream events and emits them after compute, ordered by taskOrdinal
- Debug payload + hashing/redaction behavior per §13.3:
  - `writeApplied.payloadHash` uses the canonical hashing rules
  - `writeApplied.metadata` includes/omits payload bytes based on `debugPayloads`
  - `taskFailed.errorDescription` redaction matches `debugPayloads`
- Swift Testing coverage for the tests above.

## Work breakdown

1. Add event model types exactly as spec’d.
2. Implement an event buffer with capacity and overflow policy:
   - `HiveRunOptions.eventBufferCapacity` is the buffer capacity for live events, and also bounds per-task buffering in `deterministicTokenStreaming == true` mode (per §13.4)
   - coalesce/drop rules for `modelToken` and `customDebug`
   - suspend producers for non-droppable when full
   - in `deterministicTokenStreaming == true` mode, if buffering non-droppable stream events would exceed the per-task bound, fail the step with `HiveRuntimeError.modelStreamInvalid(...)` (per §13.4)
   - emit exactly one `streamBackpressure(...)` event per step (if any drops occurred), immediately before `stepFinished`
3. Update runtime emission points to match the canonical sequencing order.
   - include attempt-start ordering: `runStarted`, optional `checkpointLoaded`, optional `runResumed`
   - enforce task-scoped ordering: `taskStarted` before any stream events; `taskFinished`/`taskFailed` after the last stream event for that task
4. Implement debug payload metadata rules for `writeApplied` and `taskFailed`.
5. Implement termination rules for:
   - errors: `HiveRunHandle.outcome` throws and `HiveRunHandle.events` throws the *same* error (per §13.5)
   - failing, non-committed steps still emit `stepStarted`, all `taskStarted`, and all `taskFinished`/`taskFailed`, but do not emit commit-scoped events (`writeApplied`, `checkpointSaved`, `streamBackpressure`, `stepFinished`)
   - cancellation (non-throwing termination)
6. Implement retry interaction for stream events (even if Plan 07 introduces retries, the event model must support §13.2):
   - `taskStarted`/`taskFinished`/`taskFailed` are emitted at most once per task (not per retry attempt)
   - `deterministicTokenStreaming == true`: buffer stream events per retry attempt; discard failed-attempt buffers
   - `deterministicTokenStreaming == false`: stream events are live and are not retracted on retry
7. Add the required tests.
   - Add at least one additional test to lock §13.2 retry/stream behavior (not currently enumerated in §17.2), e.g. “failed-attempt stream buffers are discarded in deterministicTokenStreaming mode”.

## Acceptance criteria

- Event sequences match the spec exactly for both committed and failed steps.
- Backpressure behavior is deterministic and pinned by tests.
