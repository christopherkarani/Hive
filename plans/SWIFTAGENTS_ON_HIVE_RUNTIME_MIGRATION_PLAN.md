# SwiftAgents → Hive Runtime Migration Plan

Date: 2026-02-03

Goal: Update the SwiftAgents codebase so `HiveSwiftAgents` depends on Hive as the **single source of truth** for the runtime (channels/reducers/supersteps/interrupt/resume/checkpointing), and SwiftAgents no longer carries an embedded/stub runtime.

This plan is based on repository reconnaissance of:
- SwiftAgents: `/Users/chriskarani/CodingProjects/SwiftAgents`
- Hive: `/Users/chriskarani/CodingProjects/Hive` (runtime package is at `libs/hive`)

---

## 1) Current State (Recon Summary)

### 1.1 SwiftAgents repo (today)
- SwiftAgents publishes two library products:
  - `SwiftAgents` (core agent framework)
  - `HiveSwiftAgents` (integration surface)
- `HiveSwiftAgents` currently contains an **embedded “HiveCore-like” layer** at `Sources/HiveSwiftAgents/HiveCore.swift`.
  - It defines many Hive-ish types locally (e.g., `HiveSchema`, `HiveEnvironment`, `HiveRuntime`, `CompiledHiveGraph`, etc.).
  - Its `HiveRuntime` is a **stub** (it returns a handle whose stream finishes immediately).
- The prebuilt “tool-using chat agent” graph and façade exist:
  - `Sources/HiveSwiftAgents/HiveAgents.swift`
  - `Sources/HiveSwiftAgents/SwiftAgentsToolRegistry.swift`
- Tests exist and are written against the embedded types/stub runtime:
  - `Tests/HiveSwiftAgentsTests/HiveAgentsTests.swift`
  - Many tests call graph nodes directly using a manually-constructed store view.

### 1.2 Hive repo (today)
- The real runtime is in the SwiftPM package at `libs/hive/Package.swift`, not the repo root `Package.swift`.
- `HiveCore` is a full deterministic runtime:
  - `libs/hive/Sources/HiveCore/Runtime/HiveRuntime.swift`
  - Deterministic supersteps, interrupts/resume, checkpointing hooks, stable event ordering.
- The canonical types differ in shape from SwiftAgents’ embedded copies (notably):
  - `HiveChannelKey` is `HiveChannelKey<Schema, Value>` (schema is part of the type).
  - Graph compilation uses `HiveGraphBuilder` and produces a richer `CompiledHiveGraph` (start nodes array, routers/join edges, versions, output projection).
  - `HiveEnvironment` requires `clock` and `logger` and holds optional `checkpointStore`.
  - `HiveStoreView` is not publicly constructible (intentionally), which changes test strategy.
  - Resume payload includes `interruptID` (`HiveResume(interruptID:payload:)`).
  - `HiveRunHandle` is `events + outcome`, not just an event stream.

### 1.3 Direction of dependency (required end-state)
- `SwiftAgents` depends on `HiveCore` (and optionally `HiveConduit` / `HiveCheckpointWax` for defaults).
- Hive must **not** ship a product that depends on SwiftAgents.

---

## 2) Target End-State (Ownership + Dependency Direction)

### 2.1 Source-of-truth
- Hive owns:
  - The runtime semantics and data model (`HiveCore`)
  - Optional adapters (`HiveConduit`, `HiveCheckpointWax`)
- SwiftAgents owns:
  - The “batteries-included” prebuilt graph (`HiveAgents.makeToolUsingChatAgent(...)`)
  - A façade API for running/resuming (e.g. `sendUserMessage`, `resumeToolApproval`)
  - Tool-bridging from SwiftAgents tools/registries → Hive tool registry (`SwiftAgentsToolRegistry`)

### 2.2 Public package shape
- SwiftAgents continues to ship `HiveSwiftAgents` as the primary integration library, but:
  - It imports `HiveCore` and uses the real runtime.
  - It does not re-define runtime primitives (no duplicate `HiveRuntime`, `HiveSchema`, etc.).
- Optional: Provide a separate “defaults” target to avoid forcing Conduit/Wax on all SwiftAgents users.

---

## 3) Constraints & Non-Goals

### 3.1 Constraints
- Correctness and determinism must match HiveCore semantics.
- Maintain strict concurrency (`Sendable`, actor isolation).
- Avoid runtime re-implementation in SwiftAgents; HiveCore is authoritative.
- Prefer adding missing capabilities (e.g., needed conformances/codecs) in HiveCore if they belong to Hive’s domain.

### 3.2 Non-goals
- Rewriting SwiftAgents’ existing agent DSL/orchestration system in `Sources/SwiftAgents/...`.
- Extending HiveCore runtime semantics beyond what exists today.
- Introducing new checkpoint backends beyond Wax unless required.

---

## 4) Execution Plan (Tier 2 Orchestration)

### Phase 0 — API Delta Map (Context/Research)
Output: `SWIFTAGENTS_ON_HIVE_API_DELTA.md` (internal-only mapping doc).

Tasks:
- Inventory the public API surface of SwiftAgents’ `HiveSwiftAgents` target:
  - `Sources/HiveSwiftAgents/HiveAgents.swift`
  - `Sources/HiveSwiftAgents/SwiftAgentsToolRegistry.swift`
  - `Sources/HiveSwiftAgents/HiveCore.swift` (to be removed)
- Map every used type to its HiveCore equivalent and record deltas:
  - Channel key generic shape, graph builder, store access patterns, run handle shape, resume payload, environment requirements.
- Identify test-only constructs that will disappear (notably `HiveStoreView(...)` initializers).

### Phase 1 — SwiftPM Wiring (Implementation A)
Goal: SwiftAgents compiles with Hive as a dependency (no behavior changes yet).

Tasks (SwiftAgents repo):
- Add Hive as a package dependency (local dev path first):
  - `../Hive/libs/hive`
- Update target dependencies:
  - `HiveSwiftAgents` depends on `HiveCore` product from Hive
- Optional decomposition:
  - Keep `HiveSwiftAgents` depending only on `HiveCore` + `SwiftAgents`
  - Add `HiveSwiftAgentsDefaults` that depends on `HiveConduit` + `HiveCheckpointWax` for batteries-included configs

### Phase 2 — Remove Embedded Runtime & Re-export HiveCore (Implementation A)
Goal: HiveCore becomes the single type/runtime source.

Tasks (SwiftAgents repo):
- Delete/retire `Sources/HiveSwiftAgents/HiveCore.swift`.
- Replace with a minimal module entrypoint:
  - `@_exported import HiveCore`
- Update code to use HiveCore APIs directly.

Decision point:
- If `Equatable` is needed for assertions/ergonomics on Hive types, prefer adding it in HiveCore (Hive-owned), not via downstream retroactive conformances.

### Phase 3 — Port `HiveAgents` Graph + Schema to Real HiveCore (Implementation A)
Goal: `HiveAgents.makeToolUsingChatAgent()` builds a real compiled graph using `HiveGraphBuilder` + HiveCore schema/channel APIs.

Tasks (SwiftAgents repo, `Sources/HiveSwiftAgents/HiveAgents.swift`):
- Rewrite schema declarations:
  - `HiveChannelKey<Self, Value>`
  - `HiveChannelSpec` + `.erase()` into `AnyHiveChannelSpec`
- Provide codecs for all `.checkpointed` channels (HiveCore requires codecs for checkpointing).
  - Either:
    - Add a deterministic `HiveCodec` in SwiftAgents for common `Codable` channel values, or
    - Add a standard reusable codec in HiveCore (preferred if it’s broadly useful).
- Rewrite graph construction:
  - Use `HiveGraphBuilder(start: ...)`
  - Add nodes with correct `HiveRetryPolicy` (model/tool nodes may have retries; routing/state nodes likely `.none`)
  - Add edges and routers
  - Compile to `CompiledHiveGraph`
- Update node execution input:
  - `HiveNodeInput` requires `emitStream` and `emitDebug` closures (no silent defaults).
- Update tool-approval resume logic:
  - Handle/validate `interruptID` consistently with HiveCore runtime behavior.

### Phase 4 — Update the Facade Runtime API (`HiveAgentsRuntime`) (Implementation A)
Goal: Provide a safe, Swifty façade that wraps HiveCore runtime without leaking internals.

Tasks (SwiftAgents repo):
- Stop reaching into `HiveRuntime` internals (HiveCore keeps `environment` private).
  - Store the `HiveEnvironment` alongside the runtime in the façade, or
  - Have the façade build the runtime itself and do preflight from known inputs.
- Decide on return type:
  - Prefer returning HiveCore’s `HiveRunHandle` (`events` + `outcome`).
  - If maintaining compatibility, provide a light wrapper that exposes a stream-like API but still preserves `outcome`.
- Checkpoint defaults:
  - Default `checkpointPolicy` to `.disabled` unless a checkpoint store is provided.
  - Provide a convenience initializer in “defaults” module that installs `HiveCheckpointWaxStore` if desired.

### Phase 5 — Rewrite Tests to Use Real Runtime (Test Agent; Mandatory TDD)
Goal: Replace direct node+manual-store tests with runtime-driven tests (since `HiveStoreView` is not publicly constructible).

Tasks (SwiftAgents repo, `Tests/HiveSwiftAgentsTests/HiveAgentsTests.swift`):
- Convert tests to run the runtime with a small max step budget and inspect outcomes:
  - Use `HiveRunOptions(maxSteps: ...)`
  - Use output projection to fetch channel values deterministically (e.g., `.channels(...)` projection if available)
- For deterministic message ID tests:
  - Capture the actual `taskID` from `HiveEventKind.taskStarted(...)` events and compute message IDs based on that, rather than injecting fake task IDs.
- For tool approval:
  - Assert `.interrupted` outcome contains the expected interrupt payload and checkpoint IDs where relevant.
  - Resume using `runtime.resume(threadID:interruptID:payload:options:)` and assert continuation.

### Phase 6 — Hive Repo Cleanup / Direction Enforcement (Implementation B)
Goal: Ensure Hive does not ship any SwiftAgents-dependent products and reduce confusion.

Tasks (Hive repo):
- Ensure `libs/hive/Package.swift` does not export any product/target that imports `SwiftAgents`.
- Remove or rename `libs/hive/Sources/HiveSwiftAgents` if it is redundant once SwiftAgents ships `HiveSwiftAgents`.
  - If kept, it must be clearly internal/test-only and not part of the public products.

### Phase 7 — Review & Validation (2 Review Agents)
Goal: Verify plan compliance, type safety, and determinism.

Review checklist:
- SwiftAgents no longer defines runtime primitives that belong to HiveCore.
- No loss of determinism (stable ordering, IDs, event ordering).
- Concurrency correctness (`Sendable`, actor isolation, no shared mutable state).
- Checkpointing is either:
  - Correctly codec-backed for persisted channels, or
  - Disabled by default unless configured.
- Public API is hard to misuse (explicit options, safe defaults).

---

## 5) Agent → Task Mapping

- Context/Research Agent: Phase 0
- Implementation Agent A (SwiftAgents): Phases 1–4
- Test Agent (SwiftAgents): Phase 5
- Implementation Agent B (Hive): Phase 6 (if needed)
- Review Agents (2): Phase 7

---

## 6) Known Risks / Early Decisions

- Tests must shift away from manually-constructed `HiveStoreView` to runtime-driven assertions.
- Checkpointing requires codecs for checkpointed channels; decide whether to ship a standard codec in HiveCore or a local codec in SwiftAgents.
- The façade must not depend on HiveCore internals (`environment` visibility); design the façade around explicit injected dependencies.

