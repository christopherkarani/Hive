---
sidebar_position: 2
title: Interrupt & Resume
description: Human-in-the-loop interrupt/resume protocol with typed payloads.
---

# Interrupt & Resume

## Interrupt Flow

1. Node returns `HiveNodeOutput(interrupt: HiveInterruptRequest(payload: ...))`
2. Runtime selects the interrupt from the lowest-ordinal task (deterministic)
3. Checkpoint saved with interrupt embedded
4. Run outcome: `.interrupted(HiveInterruption(interrupt:, checkpointID:))`

## Resume Flow

1. Caller invokes `runtime.resume(threadID:, interruptID:, payload:, options:)`
2. Runtime loads latest checkpoint, verifies interrupt ID matches
3. `HiveResume<Schema>` delivered to nodes via `input.run.resume`
4. Execution continues from saved frontier

## Type System

```swift
struct HiveInterruptRequest<Schema>   // Node → runtime
struct HiveInterrupt<Schema>          // Persisted (id + payload)
struct HiveResume<Schema>             // Runtime → node (resume data)
struct HiveInterruption<Schema>       // Run outcome (interrupt + checkpointID)
```

## Code Example

```swift
// Node emits interrupt
Node("review") { _ in
    Effects { Interrupt("Approve results?") }
}

// Handle interrupt
let handle = await runtime.run(threadID: tid, input: (), options: opts)
let outcome = try await handle.outcome.value
guard case let .interrupted(interruption) = outcome else { return }

// Resume
let resumed = await runtime.resume(
    threadID: tid,
    interruptID: interruption.interrupt.id,
    payload: "approved",
    options: opts
)
let final = try await resumed.outcome.value
```

## Deterministic Interrupt IDs

Interrupt IDs are computed as SHA-256 of `"HINT1" + taskID`, ensuring:
- The same workflow run always produces the same interrupt ID
- Different tasks produce different interrupt IDs
- Resume can verify the correct interrupt is being addressed

## Best Practices

- Use typed `InterruptPayload` and `ResumePayload` in your schema for compile-time safety
- Always verify the interrupt ID when resuming
- Checkpoint policy should be `.everyStep` or `.onInterrupt` for interrupt/resume workflows
- Access resume data in the next node via `input.run.resume`
