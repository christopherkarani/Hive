---
sidebar_position: 2
title: Error Handling
description: HiveRuntimeError, HiveCompilationError, and error categories.
---

# Error Handling

## HiveRuntimeError

The primary error type covering all runtime failures:

| Category | Error Cases |
|----------|-------------|
| **Store/Channel** | `unknownChannelID`, `scopeMismatch`, `channelTypeMismatch`, `storeValueMissing`, `missingCodec` |
| **Write Policy** | `updatePolicyViolation`, `taskLocalWriteNotAllowed` |
| **Checkpoint** | `checkpointStoreMissing`, `checkpointVersionMismatch`, `checkpointDecodeFailed`, `checkpointEncodeFailed`, `checkpointCorrupt` |
| **Interrupt/Resume** | `interruptPending`, `noCheckpointToResume`, `noInterruptToResume`, `resumeInterruptMismatch` |
| **Model/Inference** | `modelClientMissing`, `modelStreamInvalid`, `toolRegistryMissing`, `modelToolLoopMaxModelInvocationsExceeded` |
| **Bounds** | `stepIndexOutOfRange`, `taskOrdinalOutOfRange` |
| **Config** | `invalidRunOptions` |
| **Internal** | `internalInvariantViolation` |

### Common Scenarios

**`unknownChannelID`** — Attempting to read/write a channel not declared in the schema. Check that all channel keys match `channelSpecs`.

**`scopeMismatch`** — Writing to a task-local channel from a global context, or vice versa. Verify channel scope matches usage.

**`updatePolicyViolation`** — Writing to a `.single` update policy channel more than once per superstep. Use `.multi` for channels that receive multiple writes.

**`modelClientMissing`** — Using `ModelTurn` without providing a model client in `HiveEnvironment`. Set the `model` field.

**`noCheckpointToResume`** — Calling `resume()` without a saved checkpoint. Ensure checkpoint policy is enabled.

## HiveCompilationError

Graph compilation failures:

| Error | Cause |
|-------|-------|
| `duplicateChannelID` | Two channels share the same ID in the schema |
| `staticGraphCycleDetected` | Static edges form a cycle (router cycles are allowed) |

## HiveCheckpointQueryError

| Error | Cause |
|-------|-------|
| `unsupported` | Store does not implement the `HiveCheckpointQueryableStore` protocol |

## Error Handling Pattern

```swift
do {
    let handle = await runtime.run(threadID: tid, input: input, options: opts)
    let outcome = try await handle.outcome.value

    switch outcome {
    case .finished(let output, _):
        // Success
    case .interrupted(let interruption):
        // Handle human-in-the-loop
    case .cancelled:
        // Task was cancelled
    case .outOfSteps(let maxSteps, _, _):
        // Hit step limit
    }
} catch let error as HiveRuntimeError {
    switch error {
    case .modelClientMissing:
        // Handle missing model
    case .unknownChannelID(let id):
        // Handle unknown channel
    default:
        // Handle other errors
    }
}
```
