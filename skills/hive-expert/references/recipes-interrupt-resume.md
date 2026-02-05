# Recipe: Human Approval (Interrupt / Resume)

## Goal
Stop a run deterministically to request human approval, then resume the same thread later with a payload.

## Pattern
1. In a node, decide whether approval is needed (based on store state).
1. If yes, return `HiveNodeOutput(interrupt: HiveInterruptRequest(payload: ...))`.
1. Runtime returns `.interrupted(interruption: ...)` with:
   - `interrupt.id` (a `HiveInterruptID`)
   - `checkpointID` to persist the paused state
1. Resume later:
   - `runtime.resume(threadID: ..., interruptID: ..., payload: ..., options: ...)`
1. On the first resumed step, the node can read `input.run.resume` to access the resume payload.

## Important Semantics
- If multiple tasks request interrupts in the same step, Hive picks the smallest task ordinal (deterministic).
- Interruption is cleared only after the first **committed** resumed step.
  - If resume is cancelled before commit, the interruption may remain pending.
- You can also apply out-of-band state changes without resuming:
  - `applyExternalWrites(threadID:writes:options:)` applies writes in a deterministic synthetic step.

## Common Failure Modes
- Resume rejected:
  - Wrong `interruptID` or interruption not pending.
- Resume payload not seen:
  - Only delivered to the first resumed step; persist it to a channel if needed beyond that.

