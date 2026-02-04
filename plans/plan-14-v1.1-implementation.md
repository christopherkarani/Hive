# Plan 14 v1.1 — Operability + Deterministic Triggers + Barrier/Topic Channels (LOCKED)

**Status:** LOCKED for implementation (do not edit).

This plan implements the v1.1 tracks described in:
- `plan-14-parity-operability.md`
- `docs/plan-14/v1.1-channel-versioning-triggers.md`
- `docs/plan-14/v1.1-barrier-topic-channels.md`

The existing Plan 14 Phase 1–4 deliverables (graph description, Mermaid export, checkpoint query, stream views) already exist in `libs/hive`. This plan focuses on **implementing** the two v1.1 “design only” tracks:
1) channel versioning + `versions_seen`-style triggers, and
2) generalized barrier/topic channels as deterministic channel value types + reducers.

---

## Goals
- **Channel versions (global channels only):** Track a deterministic `UInt64` counter per global channel.
- **Deterministic triggers (opt-in):** Allow nodes to declare `runWhen` predicates (`always`, `anyOf`, `allOf`) over global channels.
- **Checkpoint/resume parity:** Persist channel versions + per-node `versionsSeen` so resume produces identical scheduling decisions.
- **Barrier/topic channels (state modeling, not scheduling):** Provide Swift-typed, misuse-resistant channel value types + reducers + helpers that remain deterministic and checkpointable.

## Constraints (non-negotiable)
- **No v1 runtime semantic changes:** supersteps, commit order, join semantics, interrupt/resume behavior, and event determinism remain unchanged.
- **Determinism-first:** all counters, snapshots, scheduling decisions, and reducers are stable across runs.
- **HiveCore remains dependency-free:** no new external packages.
- **Backwards-compatible API evolution:** additive types/protocols; avoid breaking changes.

## Non-goals
- Hash-based channel versions (counter-only in v1.1).
- Dynamic read-tracking triggers (“subscribe by reading”).
- Topic/barrier channels participating in runtime scheduling (joins remain edges).
- Remote/server runtime parity.

---

## Design Decisions (Locked)

### D1 — Channel versions are tracked for **global channels only**
- Persisted map is keyed by `HiveChannelID.rawValue`.
- Missing entry means version `0`.

### D2 — Version increment rule
- At each **committed** step, for every global channel that had **≥ 1 committed write** in that step, increment its version **exactly once**.
- Versions do **not** advance for failed/cancelled steps (no commit).
- Versions advance even if the reducer yields a semantically equal value (write activity, not equality).

### D3 — Node trigger declaration model (compile-time)
Add an optional node config:
- `runWhen: .always` (default)
- `runWhen: .anyOf(channels: [HiveChannelID])`
- `runWhen: .allOf(channels: [HiveChannelID])`

Validation at graph compile time:
- referenced channels must exist and be `.global`
- channel list must be non-empty for `anyOf`/`allOf`

### D4 — Trigger evaluation (commit-time scheduling filter)
At each commit boundary, when constructing the next frontier:
- For each **candidate task seed** produced by static edges, routers, or spawn:
  - If node `runWhen == .always` → keep seed
  - Else evaluate a predicate using:
    - `currentVersion(channel)` from the post-commit channel version map (after applying D2)
    - `seenVersion(channel)` from `versionsSeenByNodeID[nodeID]`
  - **Missing `seenVersion` counts as “changed”** for that channel (ensures initial run).
  - `anyOf`: keep if **any** channel is changed
  - `allOf`: keep if **all** channels are changed

### D5 — `versionsSeen` update point
Update `versionsSeenByNodeID` at **step start** (for tasks that will execute in that step):
- For each task whose node has non-`.always` triggers:
  - Snapshot the current channel versions for the node’s trigger channels (pre-commit)
  - Store into `versionsSeenByNodeID[nodeID][channelID]`

### D6 — Join-edge interaction: join seeds bypass triggers
Join edges schedule the target **only on a transition** from “not available” → “available”, and the barrier is cleared only when the target runs.

Therefore:
- **Seeds originating from join availability transitions must bypass trigger filtering** and always be scheduled.
- This preserves join semantics and prevents permanent stalls where a join becomes available once but is skipped forever.

### D7 — Checkpoint format vNext (HCP2)
Extend `HiveCheckpoint` with the following persisted fields:
- `checkpointFormatVersion: String` (encode `"HCP2"`)
- `channelVersionsByChannelID: [String: UInt64]`
- `versionsSeenByNodeID: [String: [String: UInt64]]`
- `updatedChannelsLastCommit: [String]` (optional convenience; for debugging/validation)

Backward compatibility:
- Decoding older checkpoints that lack these fields must be supported deterministically:
  - missing `checkpointFormatVersion` → treat as `"HCP1"`
  - missing maps → treat as empty (all versions = 0; no versionsSeen)

### D8 — Graph versioning
Keep the existing `HGV1` graph hashing algorithm unchanged for graphs with no triggers configured.

Introduce `HGV2` **only when at least one node has non-default `runWhen`**:
- `HGV2` includes trigger configuration bytes (node IDs + trigger kind + channel IDs, all deterministically ordered).
- Checkpoint resume uses the compiled graph’s `graphVersion` as today; this prevents resuming a trigger-enabled graph from a checkpoint created for a different trigger configuration.

### D9 — Barrier/topic channels are **channel value types + reducers**
These features do not affect scheduling. They are deterministic state modeling utilities intended for use as channel values.

Barrier channel:
- Typed keys/tokens + update operations (`markSeen`, `consume`)
- Reducer normalizes writes into state deterministically
- Helper functions to evaluate availability and deterministic consume

Topic channel:
- Typed keys + publish/clear operations
- Reducer normalizes writes into state deterministically
- Backpressure is explicit via bounded buffers or reduced aggregates (v1.1 ships a bounded append-only buffer policy)

---

## Test Strategy (Swift Testing; TDD)

### Channel versions + triggers
- Version increments once per committed step per written channel.
- No increments for steps with no committed writes.
- `versionsSeen` snapshots update at step start for trigger-enabled nodes.
- Trigger filtering:
  - `anyOf` and `allOf` semantics.
  - Missing versionsSeen triggers an initial run deterministically.
- Join-edge bypass:
  - Join target still runs exactly when the join becomes available, even if its triggers would otherwise prevent scheduling.
- Resume parity:
  - Run that checkpoints and resumes yields identical scheduling decisions as uninterrupted run (for trigger-enabled graphs).
- Migration:
  - Decoding an older checkpoint (missing HCP2 fields) yields deterministic default versions/versionsSeen behavior.

### Barrier/topic channels
- Reducer determinism under multiple concurrent writes (order follows existing deterministic write ordering).
- Consume semantics deterministic under mixed updates in a step.
- Checkpoint/resume parity for schemas using barrier/topic channel values (with a stable codec).

---

## Task Decomposition (Mapping)

### A) Tests (Agent: Tests Agent)
- Add failing tests for channel versions + triggers + join bypass.
- Add failing tests for checkpoint field migration/decoding defaults.
- Add failing tests for barrier/topic reducers and helpers.

### B) Implementation (Agent: Implementation Agent)
- Add trigger config types + graph builder support + compile-time validation.
- Add channel versioning state + versionsSeen state to runtime.
- Implement trigger filtering (with join-origin bypass).
- Extend checkpoint encode/decode and runtime migration defaults.
- Add barrier/topic channel types + reducers + stable codec helper (if needed).
- Update docs (`HiveCore/README.md`) and release checklist.

### C) Review (Agents: 2× Review Agents)
- API ergonomics + Sendable audit.
- Determinism audit (ordering, map key ordering assumptions, checkpoint parity).

