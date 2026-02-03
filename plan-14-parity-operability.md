# Plan 14 (Draft v0) — Parity‑Inspired UX + Operability (Post‑v1)

**Status:** DRAFT (not locked) — review findings at the end before implementation.

## Goals
1. **Graph introspection/export**: Add a stable way to describe a compiled graph and optionally export a Mermaid diagram.
2. **Checkpoint history + inspection**: Add optional APIs to list/load checkpoints (not just `loadLatest`) and inspect lightweight metadata.
3. **Derived stream views (“stream modes”)**: Keep `HiveEvent` as the single source of truth, but ship reusable adapters that filter/shape events for common consumers (UI, logs, analytics).
4. **v1.1 research track (design only)**: Explore (a) channel versioning + triggers and (b) generalized barrier/topic channels.

## Constraints (non‑negotiable)
- **Do not change v1 runtime semantics** (supersteps, commit order, interrupt/resume rules, determinism).
- **Determinism-first**: all new outputs (graph descriptions, Mermaid, checkpoint listings, stream views) must be stable across runs.
- **`HiveCore` remains dependency‑free** (no new external packages).
- **Backwards‑compatible API evolution**: additive protocols/types; avoid breaking changes.
- **SwiftAgents boundary preserved**: HiveAgents graph/facade stays in `../SwiftAgents` (per `HIVE_SPEC.md` §16).

## Non‑Goals (this plan)
- Remote/server runtime parity.
- Async routers.
- LangGraph‑style `versions_seen` triggers or generalized barrier/topic channels (implementation); this plan does **design only** for these.

---

## Phase 0 — Production Hygiene Prereqs (P0)

### 0.1 Choose the canonical SwiftPM package entrypoint
**Problem:** Repo root has a SwiftPM package stub (`Package.swift`, `Sources/Hive/Hive.swift`, `Tests/HiveTests/HiveTests.swift`) while the real implementation is in `libs/hive`.

**Decision:** `libs/hive` is the canonical Hive package.

**Actions (pick one and lock it):**
- **Option A (recommended):** Retire root SwiftPM package.
  - Remove/retire root `Package.swift`, `Sources/Hive/`, `Tests/HiveTests/`.
  - Ensure docs/tooling/CI run `cd libs/hive && swift test`.
- **Option B:** Keep root package but rename it (e.g. `HiveRepo`) and make it a wrapper that depends on `libs/hive` without duplicating a second “Hive” package identity.

**Acceptance criteria:**
- There is **exactly one obvious way** to build/test Hive from repo root, and it builds the real code.

### 0.2 Align platform minimums with the spec (or update the spec)
**Problem:** `HIVE_SPEC.md` states iOS 17/macOS 14, but `libs/hive/Package.swift` sets iOS/macOS v26.

**Actions:**
- Either lower `libs/hive/Package.swift` deployment targets to iOS 17 / macOS 14,
- or update `HIVE_SPEC.md` + docs to match v26 and explain why.

**Acceptance criteria:**
- `HIVE_SPEC.md`, repo `README.md`, and `libs/hive/Package.swift` agree on platform minimums.

### 0.3 Close missing spec‑mandated tests (by name and oracle)
`HIVE_SPEC.md` §17.1–§17.2 explicitly names required tests and golden values.

**Add tests to `libs/hive/Tests/HiveCoreTests`:**
- `testSchemaVersion_GoldenHSV1()`
  - Builds the spec’s example schema and asserts `compiled.schemaVersion == 76a2aa861605de05dad8d5c61c87aa45b56fa74a32c5986397e5cf025866b892`.
- `testGraphVersion_GoldenHGV1()`
  - Builds the spec’s example graph and asserts `compiled.graphVersion == 6614009a9f5308c8dca81acf8ed7ee4e22a3d946e77a9eb864c70db09d1b993d`.
- `testCompile_NodeIDReservedJoinCharacters_Fails()`
  - Asserts builder rejects node IDs containing `:` or `+` with `HiveCompilationError.invalidNodeIDContainsReservedJoinCharacters`.

**Acceptance criteria:**
- The tests exist with the exact names above and pass.
- The asserted golden constants match `HIVE_SPEC.md` §17.1.

---

## Phase 1 — Graph Introspection + Mermaid Export (Low Risk / High Value)

### Deliverables
- `HiveGraphDescription` (Codable, Sendable) containing:
  - `schemaVersion`, `graphVersion`
  - start node IDs (builder order)
  - all node IDs (lexicographic UTF‑8 order)
  - static edges (builder insertion order)
  - join edges (builder insertion order, with canonical join IDs + sorted parents)
  - router “from” nodes (lexicographic UTF‑8 order; router closures are opaque)
  - output projection summary
- Public API entrypoint:
  - `CompiledHiveGraph.graphDescription()` (or equivalent stable name).
- Mermaid exporter:
  - `HiveGraphMermaidExporter.export(_ description: HiveGraphDescription) -> String`

### Determinism rules (must document + enforce)
- Node listing order: lexicographic UTF‑8 by `nodeID.rawValue`.
- Routers listing order: lexicographic UTF‑8 by `nodeID.rawValue`.
- Edge listing order:
  - Description: preserve builder insertion order for static and join edges.
  - Mermaid: pick a single deterministic convention and document it (either preserve insertion order or sort; do not mix).

### Tests
- Golden test for `HiveGraphDescription` JSON (or stable string snapshot) for a tiny known graph.
- Golden test for Mermaid output for the same graph.
- Determinism test: repeated compilation of the same builder input yields identical description + Mermaid.

### Documentation
- Add a section to `libs/hive/Sources/HiveCore/README.md`:
  - “Export a graph description” (with example)
  - “Generate Mermaid” (with example)

---

## Phase 2 — Checkpoint History + Inspection (Low/Medium Risk / High Value)

### Deliverables
Add optional query capability without breaking existing stores.

#### 2.1 New protocols/types
- `HiveCheckpointSummary` (Sendable, Codable):
  - `id`, `threadID`, `runID`, `stepIndex`
  - optional: `schemaVersion`, `graphVersion`, `createdAt`, `backendID` (store-specific)
- New optional protocol (example):
  - `HiveCheckpointQueryableStore`:
    - `listCheckpoints(threadID:limit:) async throws -> [HiveCheckpointSummary]`
    - `loadCheckpoint(threadID:id:) async throws -> HiveCheckpoint<Schema>?`

#### 2.2 Type erasure support
- Extend `AnyHiveCheckpointStore` to optionally store:
  - `_listCheckpoints` closure
  - `_loadCheckpoint` closure
- Runtime helpers (optional but recommended):
  - `HiveRuntime.getCheckpointHistory(threadID:limit:)`
  - `HiveRuntime.getCheckpoint(threadID:id:)`
- Define “unsupported” behavior:
  - Either return `nil`/empty with docs, or throw a specific error (must be deterministic and documented).

#### 2.3 Wax implementation
- Implement `HiveCheckpointWaxStore` query support by scanning frame metas:
  - filter by `hive.threadID`
  - compute summaries from metadata fields
  - ordering rule must be explicit and tested (see below)

### Canonical ordering rule (must choose one and lock it)
Pick one canonical ordering for listings:
- Primary: `stepIndex` descending
- Tie-breaker: `checkpointID` lexicographic ascending/descending (pick one), or Wax frame ID (pick one)

### Tests
- `libs/hive/Tests/HiveCheckpointWaxTests`:
  - list ordering is correct (including tie-breaker).
  - load-by-id returns the correct checkpoint.
- Runtime tests (if runtime helpers exist):
  - store supports query → returns data
  - store doesn’t support query → deterministic “unsupported” behavior

### Documentation
- Add “Checkpoint inspection” section:
  - how to list checkpoints
  - how to fetch one checkpoint
  - what metadata is safe to rely on (no payloads in metadata)

---

## Phase 3 — Derived Stream Views (“Stream Modes” Utilities) (Low Risk / Medium Value)

### Deliverables
Add a small utility layer for consumers that want filtered/typed event streams.

#### 3.1 Views API
- `HiveEventStreamViews` (or similar) that wraps `AsyncThrowingStream<HiveEvent, Error>` and exposes:
  - `runs()` (run lifecycle)
  - `steps()` (step lifecycle)
  - `tasks()` (task lifecycle)
  - `writes()` (`writeApplied`)
  - `checkpoints()` (`checkpointSaved`/`checkpointLoaded`)
  - `model()` (`modelInvocationStarted`/`modelToken`/`modelInvocationFinished`)
  - `tools()` (`toolInvocationStarted`/`toolInvocationFinished`)
  - `debug()` (`customDebug`)

Each view yields a small typed event struct (Sendable) so UIs don’t pattern‑match `HiveEventKind` everywhere.

#### 3.2 Semantics
- Views must preserve event order relative to the original stream for events they include.
- Views must propagate termination and errors.
- Cancellation must stop internal tasks/pumps promptly.

### Tests
- Filtering correctness tests for each view.
- Order preservation test (mix events, assert view output order matches source subset order).
- Error propagation test (source throws, view throws).
- Cancellation test (best-effort): cancelling consumer should terminate the view promptly.

### Documentation
- Add “Stream views” section with examples:
  - progress UI (steps/tasks)
  - chat UI (model tokens)

---

## Phase 4 — Docs + Release Checklist Updates
Update `docs/hive-release-checklist.md`:
- Add a validation step for graph description + Mermaid export.
- Add a validation step for checkpoint listing + load-by-id (Wax store).
- Add a validation step demonstrating at least one stream view usage.

---

## Phase 5 — v1.1 Research Track (Design Only; No Code Yet)

### 5.1 Channel versioning + versions_seen‑style triggers (design doc)
Deliver a design doc covering:
- What a “channel version” is (counter vs hash).
- What is persisted in checkpoints (versions, updated-channels, versions_seen).
- Trigger rules (when nodes run) while keeping determinism.
- Checkpoint format versioning/migration strategy.
- Test plan to prevent subtle regressions.

### 5.2 Generalized barrier/topic channels (design doc)
Deliver a design doc covering:
- User-facing API shape (Swift‑typed, hard to misuse).
- State representation and checkpointing implications.
- Determinism/backpressure semantics.
- Minimal viable subset vs full generality.

---

# Review Findings (Gaps / Potential Bugs in This Plan)

1. **Lock point missing:** Define when this draft becomes the locked implementation plan and what decisions are prerequisites (Phase 0).
2. **Checkpoint listing scalability risk:** Wax metadata scan may degrade with many checkpoints; define expected scale and whether an index strategy is needed.
3. **Checkpoint ordering tie-breaker not chosen:** Must select one canonical tie-breaker and test it.
4. **Terminology risk (“stream modes”):** Could imply LangGraph parity; consider calling these “views” in API and docs to avoid overpromising.
5. **Mermaid router representation unspecified:** Must define a single deterministic convention for “router present” (annotation style) so output doesn’t drift.
6. **Public API review gate missing:** Add an explicit “API ergonomics + Sendable audit” gate before release.
