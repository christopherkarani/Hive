---
sidebar_position: 1
title: Checkpointing
description: Checkpoint format, checkpoint store protocol, and checkpoint policies.
---

# Checkpointing

## Checkpoint Format

`HiveCheckpoint<Schema>` captures a complete runtime state snapshot:

| Field | Type | Purpose |
|-------|------|---------|
| `id` | `HiveCheckpointID` | Deterministic identifier |
| `threadID` | `HiveThreadID` | Thread this belongs to |
| `stepIndex` | `Int` | Superstep index at save time |
| `globalDataByChannelID` | `[String: Data]` | Encoded global store values |
| `frontier` | `[HiveCheckpointTask]` | Persisted frontier tasks |
| `joinBarrierSeenByJoinID` | `[String: [String]]` | Join barrier state |
| `interruption` | `HiveInterrupt?` | Pending interrupt |
| `channelVersionsByChannelID` | `[String: UInt64]` | Version counters |

## Store Protocol

```swift
public protocol HiveCheckpointStore: Sendable {
    associatedtype Schema: HiveSchema
    func save(_ checkpoint: HiveCheckpoint<Schema>) async throws
    func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>?
}
```

For history browsing, `HiveCheckpointQueryableStore` adds `listCheckpoints` and `loadCheckpoint`.

## Checkpoint Policy

```swift
public enum HiveCheckpointPolicy: Sendable {
    case disabled
    case everyStep
    case every(steps: Int)
    case onInterrupt
}
```

| Policy | Behavior |
|--------|----------|
| `.disabled` | No checkpoints saved |
| `.everyStep` | Save after every superstep |
| `.every(steps: N)` | Save every N supersteps |
| `.onInterrupt` | Save only when a node triggers an interrupt |

## Deterministic Checkpoint IDs

Checkpoint IDs are computed as SHA-256 of `"HCP1" + runID + stepIndex`, ensuring identical runs produce identical checkpoint identifiers.

## Persistence

Channels with `.checkpointed` persistence are included in checkpoint snapshots. Channels with `.untracked` or `.ephemeral` persistence are excluded.

See [HiveCheckpointWax](/docs/ecosystem/adapters#hivecheckpointwax) for the Wax-backed persistent implementation.
